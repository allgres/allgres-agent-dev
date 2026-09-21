-- Capability discovery and measured reuse.
--
-- This layer deliberately separates discovery from execution.  A vector
-- result is a candidate, never authority: rank_capabilities applies the
-- same permission check as the eventual delegate/call/run path and returns
-- metadata for the model to inspect before it chooses an existing action.

CREATE TABLE IF NOT EXISTS allgres_private.capability_index (
  capability_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  capability_type     text NOT NULL CHECK (capability_type IN ('agent','function','procedure','plan')),
  source_id           uuid,
  name                text NOT NULL,
  description         text NOT NULL,
  search_document     text NOT NULL,
  metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
  lifecycle           text NOT NULL DEFAULT 'published'
    CHECK (lifecycle IN ('draft','published','disabled')),
  content_hash        text NOT NULL,
  embedding           double precision[],
  embedding_model     text,
  embedding_updated_at timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (capability_type, source_id)
);

CREATE INDEX IF NOT EXISTS capability_index_name_idx
  ON allgres_private.capability_index (capability_type, name);
CREATE INDEX IF NOT EXISTS capability_index_published_idx
  ON allgres_private.capability_index (updated_at DESC)
  WHERE lifecycle = 'published';

ALTER TABLE allgres_private.capability_index
  DROP CONSTRAINT IF EXISTS capability_index_lifecycle_check;
ALTER TABLE allgres_private.capability_index
  ADD CONSTRAINT capability_index_lifecycle_check CHECK
    (lifecycle IN ('draft','testing','review_pending','published','deprecated','disabled'));

CREATE TABLE IF NOT EXISTS allgres_private.capability_versions (
  capability_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  capability_id uuid NOT NULL REFERENCES allgres_private.capability_index(capability_id) ON DELETE CASCADE,
  version int NOT NULL,
  lifecycle text NOT NULL,
  snapshot jsonb NOT NULL,
  test_result jsonb,
  change_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(capability_id,version)
);

-- Evaluation is durable evidence, not a boolean supplied by the dashboard.
-- The runner deliberately evaluates only immutable, already-recorded facts:
-- build state, normalized contract/risk metadata, permission-scoped execution
-- outcomes, and a comparison with the currently published version.  It never
-- invokes a write-capable capability merely because an operator opened review.
CREATE TABLE IF NOT EXISTS allgres_private.capability_evaluations (
  evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  capability_id uuid NOT NULL REFERENCES allgres_private.capability_index(capability_id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('passed','failed')),
  isolated boolean NOT NULL DEFAULT true,
  checks jsonb NOT NULL,
  candidate_metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  baseline_metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  regression boolean NOT NULL DEFAULT false,
  content_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS capability_evaluations_latest_idx
  ON allgres_private.capability_evaluations(capability_id,created_at DESC);

CREATE OR REPLACE FUNCTION allgres_private.evaluate_capability(p_capability_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE c allgres_private.capability_index%ROWTYPE; v_checks jsonb; v_candidate jsonb;
  v_baseline jsonb; v_passed boolean; v_regression boolean; v_id uuid;
  v_runs bigint; v_success bigint; v_baseline_rate numeric; v_candidate_rate numeric;
BEGIN
  SELECT * INTO c FROM allgres_private.capability_index WHERE capability_id=p_capability_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'capability not found' USING ERRCODE='P0001'; END IF;

  SELECT count(*),count(*) FILTER (WHERE e.outcome='succeeded') INTO v_runs,v_success
  FROM allgres_private.capability_search_events e
  WHERE e.selected_capability_id=p_capability_id AND e.outcome IN ('succeeded','failed');
  v_candidate_rate:=CASE WHEN v_runs=0 THEN NULL ELSE v_success::numeric/v_runs END;
  SELECT (v.test_result->'candidate_metrics'->>'success_rate')::numeric INTO v_baseline_rate
  FROM allgres_private.capability_versions v
  WHERE v.capability_id=p_capability_id AND v.lifecycle='published'
    AND v.test_result IS NOT NULL ORDER BY v.version DESC LIMIT 1;
  v_regression:=v_candidate_rate IS NOT NULL AND v_baseline_rate IS NOT NULL
    AND v_candidate_rate < v_baseline_rate;
  v_checks:=jsonb_build_object(
    'source_present',c.source_id IS NOT NULL,
    'description_present',length(trim(c.description))>0,
    'input_contract_present',c.capability_type='agent' OR c.metadata ? 'param_schema'
      OR c.metadata ? 'input_schema',
    'risk_declared',c.metadata ? 'risk',
    'build_ready',COALESCE(c.metadata->>'build_status','built')='built',
    'permission_filtered',c.capability_type IN ('agent','function','procedure'),
    'baseline_not_regressed',NOT v_regression
  );
  v_passed:=NOT (v_checks @> '{"source_present":false}'::jsonb)
    AND NOT (v_checks @> '{"description_present":false}'::jsonb)
    AND NOT (v_checks @> '{"input_contract_present":false}'::jsonb)
    AND NOT (v_checks @> '{"risk_declared":false}'::jsonb)
    AND NOT (v_checks @> '{"build_ready":false}'::jsonb)
    AND NOT v_regression;
  v_candidate:=jsonb_build_object('runs',v_runs,'successes',v_success,'success_rate',v_candidate_rate);
  v_baseline:=jsonb_build_object('success_rate',v_baseline_rate);
  INSERT INTO allgres_private.capability_evaluations
    (capability_id,status,checks,candidate_metrics,baseline_metrics,regression,content_hash)
  VALUES (p_capability_id,CASE WHEN v_passed THEN 'passed' ELSE 'failed' END,
    v_checks,v_candidate,v_baseline,v_regression,c.content_hash) RETURNING evaluation_id INTO v_id;
  PERFORM allgres_private.audit('capability.evaluate',jsonb_build_object(
    'capability_id',p_capability_id,'evaluation_id',v_id,'passed',v_passed,'regression',v_regression));
  RETURN jsonb_build_object('evaluation_id',v_id,'passed',v_passed,'checks',v_checks,
    'candidate_metrics',v_candidate,'baseline_metrics',v_baseline,'regression',v_regression);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.transition_capability(
  p_capability_id uuid,p_lifecycle text,p_test_result jsonb DEFAULT NULL,p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE c allgres_private.capability_index%ROWTYPE; v_version int;
  v_evaluation allgres_private.capability_evaluations%ROWTYPE;
BEGIN
  IF p_lifecycle NOT IN ('draft','testing','review_pending','published','deprecated','disabled') THEN
    RAISE EXCEPTION 'invalid capability lifecycle' USING ERRCODE='22023';
  END IF;
  SELECT * INTO c FROM allgres_private.capability_index WHERE capability_id=p_capability_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'capability not found' USING ERRCODE='P0001'; END IF;
  IF c.lifecycle='published' AND p_lifecycle IN ('draft','testing','review_pending') THEN
    RAISE EXCEPTION 'published capabilities are immutable; create a new source version' USING ERRCODE='P0001';
  END IF;
  IF p_lifecycle='published' AND c.lifecycle<>'review_pending' THEN
    RAISE EXCEPTION 'only review_pending capabilities may be published' USING ERRCODE='P0001';
  END IF;
  IF p_lifecycle='published' THEN
    SELECT * INTO v_evaluation FROM allgres_private.capability_evaluations
    WHERE evaluation_id=NULLIF(p_test_result->>'evaluation_id','')::uuid
      AND capability_id=p_capability_id AND status='passed' AND isolated
      AND content_hash=c.content_hash;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'a current passing isolated evaluation is required to publish' USING ERRCODE='P0001';
    END IF;
    p_test_result:=jsonb_build_object('evaluation_id',v_evaluation.evaluation_id,
      'passed',true,'checks',v_evaluation.checks,'candidate_metrics',v_evaluation.candidate_metrics,
      'baseline_metrics',v_evaluation.baseline_metrics,'regression',v_evaluation.regression);
  END IF;
  SELECT COALESCE(max(version),0)+1 INTO v_version FROM allgres_private.capability_versions
  WHERE capability_id=p_capability_id;
  INSERT INTO allgres_private.capability_versions
    (capability_id,version,lifecycle,snapshot,test_result,change_note)
  VALUES (p_capability_id,v_version,c.lifecycle,
    jsonb_build_object('name',c.name,'description',c.description,'search_document',c.search_document,
      'metadata',c.metadata,'lifecycle',c.lifecycle,'content_hash',c.content_hash),p_test_result,left(p_note,2000));
  UPDATE allgres_private.capability_index SET lifecycle=p_lifecycle,updated_at=now()
  WHERE capability_id=p_capability_id;
  PERFORM allgres_private.audit('capability.transition',jsonb_build_object(
    'capability_id',p_capability_id,'from',c.lifecycle,'to',p_lifecycle,'version',v_version));
  RETURN jsonb_build_object('ok',true,'version',v_version,'lifecycle',p_lifecycle);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.rollback_capability(p_capability_id uuid,p_version int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v allgres_private.capability_versions%ROWTYPE; v_new int; c allgres_private.capability_index%ROWTYPE;
BEGIN
  SELECT * INTO v FROM allgres_private.capability_versions
  WHERE capability_id=p_capability_id AND version=p_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'capability version not found' USING ERRCODE='P0001'; END IF;
  SELECT * INTO c FROM allgres_private.capability_index WHERE capability_id=p_capability_id FOR UPDATE;
  IF c.capability_type='procedure' AND v.snapshot->'metadata' ? 'generation' THEN
    PERFORM allgres_public.fn_rollback_procedure(c.source_id,(v.snapshot->'metadata'->>'generation')::int);
  ELSIF c.capability_type='function' AND v.snapshot->'metadata' ? 'generation' THEN
    PERFORM allgres_public.fn_rollback_function(c.source_id,(v.snapshot->'metadata'->>'generation')::int);
  END IF;
  SELECT COALESCE(max(version),0)+1 INTO v_new FROM allgres_private.capability_versions
  WHERE capability_id=p_capability_id;
  INSERT INTO allgres_private.capability_versions(capability_id,version,lifecycle,snapshot,change_note)
  SELECT c.capability_id,v_new,c.lifecycle,
    jsonb_build_object('name',c.name,'description',c.description,'search_document',c.search_document,
      'metadata',c.metadata,'lifecycle',c.lifecycle,'content_hash',c.content_hash),
    'rollback before restoring version '||p_version
  FROM allgres_private.capability_index c WHERE c.capability_id=p_capability_id;
  UPDATE allgres_private.capability_index SET
    name=v.snapshot->>'name',description=v.snapshot->>'description',
    search_document=v.snapshot->>'search_document',metadata=v.snapshot->'metadata',
    content_hash=v.snapshot->>'content_hash',lifecycle='published',embedding=NULL,
    embedding_model=NULL,embedding_updated_at=NULL,updated_at=now()
  WHERE capability_id=p_capability_id;
  PERFORM allgres_private.queue_capability_embedding(p_capability_id);
  PERFORM allgres_private.audit('capability.rollback',jsonb_build_object(
    'capability_id',p_capability_id,'restored_version',p_version,'saved_version',v_new));
  RETURN jsonb_build_object('ok',true,'restored_version',p_version,'saved_version',v_new);
END;
$fn$;

CREATE TABLE IF NOT EXISTS allgres_private.capability_search_events (
  event_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id              uuid REFERENCES allgres_private.tasks(task_id) ON DELETE SET NULL,
  requester_agent_id   uuid REFERENCES allgres_private.agents(agent_id) ON DELETE SET NULL,
  query_text           text,
  embedding_model      text,
  candidates           jsonb NOT NULL DEFAULT '[]'::jsonb,
  selected_capability_id uuid REFERENCES allgres_private.capability_index(capability_id) ON DELETE SET NULL,
  outcome              text CHECK (outcome IN ('presented','selected','succeeded','failed','rejected')),
  latency_ms           int CHECK (latency_ms IS NULL OR latency_ms >= 0),
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS capability_search_events_requester_idx
  ON allgres_private.capability_search_events (requester_agent_id, created_at DESC);
ALTER TABLE allgres_private.capability_search_events
  ADD COLUMN IF NOT EXISTS expected_capability_id uuid REFERENCES allgres_private.capability_index(capability_id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS user_corrected boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS attempt_number int NOT NULL DEFAULT 1 CHECK (attempt_number > 0),
  ADD COLUMN IF NOT EXISTS execution_latency_ms int CHECK (execution_latency_ms IS NULL OR execution_latency_ms >= 0),
  ADD COLUMN IF NOT EXISTS cost_usd numeric CHECK (cost_usd IS NULL OR cost_usd >= 0);

-- Add a third target to the existing background embedding queue.  The
-- worker transports opaque HTTP calls and therefore needs no Rust change.
ALTER TABLE allgres_private.embedding_calls
  ADD COLUMN IF NOT EXISTS capability_id uuid
    REFERENCES allgres_private.capability_index(capability_id) ON DELETE CASCADE;
ALTER TABLE allgres_private.embedding_calls DROP CONSTRAINT IF EXISTS embedding_calls_target_check;
ALTER TABLE allgres_private.embedding_calls ADD CONSTRAINT embedding_calls_target_check
  CHECK (num_nonnulls(agent_id, memory_id, capability_id) = 1);

CREATE OR REPLACE FUNCTION allgres_private.queue_capability_embedding(p_capability_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_provider allgres_private.llm_providers%ROWTYPE;
  v_document text;
  v_url text;
  v_reason text;
BEGIN
  SELECT * INTO v_provider FROM allgres_private.llm_providers
  WHERE purpose = 'embedding' AND is_enabled ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT search_document INTO v_document
  FROM allgres_private.capability_index
  WHERE capability_id = p_capability_id AND lifecycle = 'published';
  IF v_document IS NULL THEN RETURN; END IF;

  v_url := v_provider.base_url || '/embeddings';
  v_reason := allgres_private.check_outbound_url(v_url, v_provider.allow_private_network);
  IF v_reason IS NOT NULL THEN RETURN; END IF;

  DELETE FROM allgres_private.embedding_calls
  WHERE capability_id = p_capability_id AND status = 'queued';
  INSERT INTO allgres_private.embedding_calls
    (capability_id, provider_id, model, url, request_headers, request_body, allow_private, status)
  VALUES (
    p_capability_id, v_provider.provider_id, v_provider.embedding_model, v_url,
    jsonb_build_object('content-type','application/json'),
    jsonb_build_object('model',v_provider.embedding_model,'input',left(v_document,8000)),
    v_provider.allow_private_network, 'queued'
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.upsert_capability(
  p_type text, p_source_id uuid, p_name text, p_description text,
  p_metadata jsonb DEFAULT '{}'::jsonb, p_lifecycle text DEFAULT 'published'
) RETURNS uuid
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_document text;
  v_hash text;
  v_id uuid;
  v_old_hash text;
  v_has_embedding boolean;
BEGIN
  v_document := concat_ws(E'\n',
    'type: ' || p_type, 'name: ' || p_name,
    'description: ' || COALESCE(p_description,''),
    'metadata: ' || COALESCE(p_metadata,'{}'::jsonb)::text
  );
  v_hash := md5(v_document);
  SELECT capability_id, content_hash, embedding IS NOT NULL INTO v_id, v_old_hash, v_has_embedding
  FROM allgres_private.capability_index
  WHERE capability_type = p_type AND source_id = p_source_id FOR UPDATE;

  IF v_id IS NULL THEN
    INSERT INTO allgres_private.capability_index
      (capability_type, source_id, name, description, search_document, metadata, lifecycle, content_hash)
    VALUES (p_type,p_source_id,p_name,p_description,v_document,COALESCE(p_metadata,'{}'::jsonb),p_lifecycle,v_hash)
    RETURNING capability_id INTO v_id;
  ELSE
    UPDATE allgres_private.capability_index SET
      name=p_name, description=p_description, search_document=v_document,
      metadata=COALESCE(p_metadata,'{}'::jsonb), lifecycle=p_lifecycle,
      content_hash=v_hash,
      embedding=CASE WHEN content_hash IS DISTINCT FROM v_hash THEN NULL ELSE embedding END,
      embedding_model=CASE WHEN content_hash IS DISTINCT FROM v_hash THEN NULL ELSE embedding_model END,
      embedding_updated_at=CASE WHEN content_hash IS DISTINCT FROM v_hash THEN NULL ELSE embedding_updated_at END,
      updated_at=now()
    WHERE capability_id=v_id;
  END IF;
  IF v_old_hash IS DISTINCT FROM v_hash OR v_old_hash IS NULL OR NOT COALESCE(v_has_embedding,false) THEN
    PERFORM allgres_private.queue_capability_embedding(v_id);
  END IF;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.sync_capability_index()
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE r record; v_count int := 0;
BEGIN
  FOR r IN SELECT a.agent_id id,a.name,COALESCE(p.system_prompt,'') description,
      jsonb_build_object('is_system',a.is_system,'input_schema',jsonb_build_object('message','string'),
        'risk','delegation') metadata,a.is_active
    FROM allgres_private.agents a LEFT JOIN allgres_private.policies p USING(agent_id)
  LOOP
    PERFORM allgres_private.upsert_capability('agent',r.id,r.name,r.description,r.metadata,
      CASE WHEN r.is_active THEN 'published' ELSE 'disabled' END); v_count:=v_count+1;
  END LOOP;
  FOR r IN SELECT function_id id,name,description,
      jsonb_build_object('handler',handler,'param_schema',param_schema,'args_template',args_template,
        'build_status',build_status,'generation',generation,'risk',CASE handler WHEN 'plpgsql' THEN 'database_write'
          WHEN 'http_get' THEN 'external_read' WHEN 'mcp_call' THEN 'external_call' ELSE 'normal' END,
        'requires_approval',handler IN ('plpgsql','mcp_call')) metadata,is_active
    FROM allgres_private.functions
  LOOP
    PERFORM allgres_private.upsert_capability('function',r.id,r.name,r.description,r.metadata,
      CASE WHEN r.is_active AND (r.metadata->>'build_status') IN ('built',NULL) THEN 'published'
           WHEN r.is_active THEN 'draft' ELSE 'disabled' END); v_count:=v_count+1;
  END LOOP;
  FOR r IN SELECT procedure_id id,name,content description,
      jsonb_build_object('generation',generation,'build_status',build_status,
        'input_schema',jsonb_build_object('args','object'),'risk','database_write',
        'requires_approval',true) metadata,is_active
    FROM allgres_private.procedures
  LOOP
    PERFORM allgres_private.upsert_capability('procedure',r.id,r.name,r.description,r.metadata,
      CASE WHEN r.is_active AND (r.metadata->>'build_status')='built' THEN 'published'
           WHEN r.is_active THEN 'draft' ELSE 'disabled' END); v_count:=v_count+1;
  END LOOP;
  RETURN jsonb_build_object('ok',true,'indexed',v_count);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.capability_source_changed()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM allgres_private.sync_capability_index();
  RETURN NULL;
END;
$fn$;
DROP TRIGGER IF EXISTS capability_agents_changed ON allgres_private.agents;
CREATE TRIGGER capability_agents_changed AFTER INSERT OR UPDATE OF name,is_active ON allgres_private.agents
  FOR EACH STATEMENT EXECUTE FUNCTION allgres_private.capability_source_changed();
DROP TRIGGER IF EXISTS capability_policies_changed ON allgres_private.policies;
CREATE TRIGGER capability_policies_changed AFTER INSERT OR UPDATE OF system_prompt ON allgres_private.policies
  FOR EACH STATEMENT EXECUTE FUNCTION allgres_private.capability_source_changed();
DROP TRIGGER IF EXISTS capability_functions_changed ON allgres_private.functions;
CREATE TRIGGER capability_functions_changed AFTER INSERT OR UPDATE OF description,param_schema,args_template,is_active,build_status ON allgres_private.functions
  FOR EACH STATEMENT EXECUTE FUNCTION allgres_private.capability_source_changed();
DROP TRIGGER IF EXISTS capability_procedures_changed ON allgres_private.procedures;
CREATE TRIGGER capability_procedures_changed AFTER INSERT OR UPDATE OF content,is_active,build_status ON allgres_private.procedures
  FOR EACH STATEMENT EXECUTE FUNCTION allgres_private.capability_source_changed();

CREATE OR REPLACE FUNCTION allgres_private.ensure_capability_vector_index()
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE v_dims int; v_schema text; v_idx oid; v_def text;
BEGIN
  IF NOT allgres_private.vector_available() THEN RETURN; END IF;
  SELECT array_length(embedding,1) INTO v_dims FROM allgres_private.capability_index
  WHERE embedding IS NOT NULL ORDER BY embedding_updated_at DESC NULLS LAST LIMIT 1;
  IF v_dims IS NULL THEN RETURN; END IF;
  v_schema:=allgres_private.vector_schema();
  v_idx:=to_regclass('allgres_private.capability_embedding_hnsw_idx')::oid;
  IF v_idx IS NOT NULL THEN
    SELECT pg_get_indexdef(v_idx) INTO v_def;
    IF v_def LIKE '%vector('||v_dims||')%' THEN RETURN; END IF;
    EXECUTE 'DROP INDEX allgres_private.capability_embedding_hnsw_idx';
  END IF;
  EXECUTE format('CREATE INDEX capability_embedding_hnsw_idx ON allgres_private.capability_index USING hnsw ((embedding::%I.vector(%s)) %I.vector_cosine_ops) WHERE embedding IS NOT NULL AND lifecycle = ''published'' AND array_length(embedding,1) = %s',v_schema,v_dims,v_schema,v_dims);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.rank_capabilities_by_embedding(
  p_query_embedding double precision[], p_requester_agent_id uuid,
  p_expected_model text, p_query_text text DEFAULT NULL, p_limit int DEFAULT 5,
  p_task_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_out jsonb; v_dims int; v_n int:=GREATEST(1,LEAST(COALESCE(p_limit,5),20)); v_started timestamptz:=clock_timestamp();
BEGIN
  v_dims:=array_length(p_query_embedding,1); IF v_dims IS NULL THEN RETURN '[]'::jsonb; END IF;
  IF allgres_private.vector_available() THEN
    EXECUTE format($sql$
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'capability_id',capability_id,'type',capability_type,'name',name,
        'description',left(description,1000),'metadata',metadata,
        'similarity',similarity,'keyword_match',keyword_match
      ) ORDER BY score DESC),'[]'::jsonb)
      FROM (
        SELECT c.*,
          1-(c.embedding::%2$I.vector(%1$s) OPERATOR(%2$I.<=>) $1::%2$I.vector(%1$s)) similarity,
          CASE WHEN NULLIF(trim($4),'') IS NOT NULL
            AND to_tsvector('simple',c.search_document) @@ plainto_tsquery('simple',$4)
            THEN true ELSE false END keyword_match,
          1-(c.embedding::%2$I.vector(%1$s) OPERATOR(%2$I.<=>) $1::%2$I.vector(%1$s))+
          CASE WHEN NULLIF(trim($4),'') IS NOT NULL
            AND to_tsvector('simple',c.search_document) @@ plainto_tsquery('simple',$4)
            THEN 0.15 ELSE 0 END score
        FROM allgres_private.capability_index c
        WHERE c.lifecycle='published' AND c.embedding IS NOT NULL
          AND array_length(c.embedding,1)=%1$s AND c.embedding_model=$3
          AND CASE c.capability_type
            WHEN 'agent' THEN allgres_private.agent_has_permission($2,'agent',c.name)
            WHEN 'function' THEN allgres_private.agent_has_permission($2,'function',c.name)
            WHEN 'procedure' THEN allgres_private.agent_has_permission($2,'procedure',c.name)
            ELSE false END
        ORDER BY c.embedding::%2$I.vector(%1$s) OPERATOR(%2$I.<=>) $1::%2$I.vector(%1$s)
        LIMIT $5
      ) ranked
    $sql$,v_dims,allgres_private.vector_schema())
    INTO v_out USING p_query_embedding,p_requester_agent_id,p_expected_model,p_query_text,v_n;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'capability_id',capability_id,'type',capability_type,'name',name,
      'description',left(description,1000),'metadata',metadata,'similarity',similarity,
      'keyword_match',keyword_match) ORDER BY score DESC),'[]'::jsonb) INTO v_out
    FROM (
      SELECT c.*,allgres_private.cosine_similarity(c.embedding,p_query_embedding) similarity,
        CASE WHEN NULLIF(trim(p_query_text),'') IS NOT NULL AND to_tsvector('simple',c.search_document)
          @@ plainto_tsquery('simple',p_query_text) THEN true ELSE false END keyword_match,
        COALESCE(allgres_private.cosine_similarity(c.embedding,p_query_embedding),-1)+
        CASE WHEN NULLIF(trim(p_query_text),'') IS NOT NULL AND to_tsvector('simple',c.search_document)
          @@ plainto_tsquery('simple',p_query_text) THEN 0.15 ELSE 0 END score
      FROM allgres_private.capability_index c
      WHERE c.lifecycle='published' AND c.embedding IS NOT NULL
        AND array_length(c.embedding,1)=v_dims AND c.embedding_model=p_expected_model
        AND CASE c.capability_type
          WHEN 'agent' THEN allgres_private.agent_has_permission(p_requester_agent_id,'agent',c.name)
          WHEN 'function' THEN allgres_private.agent_has_permission(p_requester_agent_id,'function',c.name)
          WHEN 'procedure' THEN allgres_private.agent_has_permission(p_requester_agent_id,'procedure',c.name)
          ELSE false END ORDER BY score DESC NULLS LAST LIMIT v_n
    ) ranked;
  END IF;
  INSERT INTO allgres_private.capability_search_events
    (task_id,requester_agent_id,query_text,embedding_model,candidates,outcome,latency_ms)
  VALUES (p_task_id,p_requester_agent_id,left(p_query_text,2000),p_expected_model,v_out,'presented',
    GREATEST(0,(extract(epoch FROM clock_timestamp()-v_started)*1000)::int));
  RETURN v_out;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_capability_metrics()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=allgres_private,pg_temp AS $fn$
  SELECT jsonb_build_object(
    'searches',count(*),
    'selected',count(*) FILTER (WHERE selected_capability_id IS NOT NULL),
    'succeeded',count(*) FILTER (WHERE outcome='succeeded'),
    'failed',count(*) FILTER (WHERE outcome='failed'),
    'rejected',count(*) FILTER (WHERE outcome='rejected'),
    'selection_rate',round((count(*) FILTER (WHERE selected_capability_id IS NOT NULL))::numeric /
      NULLIF(count(*),0),4),
    'execution_success_rate',round((count(*) FILTER (WHERE outcome='succeeded'))::numeric /
      NULLIF(count(*) FILTER (WHERE outcome IN ('succeeded','failed')),0),4),
    'first_try_success_rate',round((count(*) FILTER (WHERE outcome='succeeded' AND attempt_number=1))::numeric /
      NULLIF(count(*) FILTER (WHERE outcome IN ('succeeded','failed') AND attempt_number=1),0),4),
    'recall_at_5',round((count(*) FILTER (WHERE expected_capability_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(candidates) x
      WHERE x->>'capability_id'=expected_capability_id::text)))::numeric /
      NULLIF(count(*) FILTER (WHERE expected_capability_id IS NOT NULL),0),4),
    'selection_accuracy',round((count(*) FILTER (WHERE expected_capability_id=selected_capability_id))::numeric /
      NULLIF(count(*) FILTER (WHERE expected_capability_id IS NOT NULL AND selected_capability_id IS NOT NULL),0),4),
    'correction_rate',round((count(*) FILTER (WHERE user_corrected))::numeric/NULLIF(count(*),0),4),
    'reuse_rate',round((count(*) FILTER (WHERE selected_capability_id IS NOT NULL))::numeric/NULLIF(count(*),0),4),
    'average_search_latency_ms',round(avg(latency_ms),2),
    'average_execution_latency_ms',round(avg(execution_latency_ms),2),
    'total_cost_usd',COALESCE(round(sum(cost_usd),6),0)
  ) FROM allgres_private.capability_search_events
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.label_capability_search(
  p_event_id uuid,p_expected_capability_id uuid,p_user_corrected boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  UPDATE allgres_private.capability_search_events SET
    expected_capability_id=p_expected_capability_id,user_corrected=COALESCE(p_user_corrected,false)
  WHERE event_id=p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'capability search event not found' USING ERRCODE='P0001'; END IF;
  PERFORM allgres_private.audit('capability.search_label',jsonb_build_object(
    'event_id',p_event_id,'expected_capability_id',p_expected_capability_id,'user_corrected',p_user_corrected));
  RETURN jsonb_build_object('ok',true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.mark_capability_selected(
  p_task_id uuid,p_type text,p_name text
) RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE v_event uuid; v_cap uuid;
BEGIN
  SELECT event_id INTO v_event FROM allgres_private.capability_search_events
  WHERE task_id=p_task_id AND outcome='presented' ORDER BY created_at DESC LIMIT 1;
  IF v_event IS NULL THEN RETURN; END IF;
  SELECT capability_id INTO v_cap FROM allgres_private.capability_index
  WHERE capability_type=p_type AND name=p_name AND lifecycle='published' LIMIT 1;
  IF v_cap IS NOT NULL THEN
    UPDATE allgres_private.capability_search_events
    SET selected_capability_id=v_cap,outcome='selected' WHERE event_id=v_event;
  END IF;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.mark_capability_outcome(
  p_task_id uuid,p_type text,p_name text,p_succeeded boolean
) RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  UPDATE allgres_private.capability_search_events e
  SET outcome=CASE WHEN p_succeeded THEN 'succeeded' ELSE 'failed' END,
      execution_latency_ms=GREATEST(0,(extract(epoch FROM clock_timestamp()-e.created_at)*1000)::int)
  WHERE e.event_id=(
    SELECT e2.event_id FROM allgres_private.capability_search_events e2
    JOIN allgres_private.capability_index c ON c.capability_id=e2.selected_capability_id
    WHERE e2.task_id=p_task_id AND c.capability_type=p_type AND c.name=p_name
      AND e2.outcome='selected' ORDER BY e2.created_at DESC LIMIT 1
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.record_capability_remote_cost(
  p_task_id uuid,p_cost_usd numeric
) RETURNS void LANGUAGE sql AS $fn$
  UPDATE allgres_private.capability_search_events e
  SET cost_usd=COALESCE(e.cost_usd,0)+GREATEST(COALESCE(p_cost_usd,0),0)
  WHERE e.event_id=(SELECT e2.event_id FROM allgres_private.capability_search_events e2
    WHERE e2.task_id=p_task_id AND e2.selected_capability_id IS NOT NULL
    ORDER BY e2.created_at DESC LIMIT 1)
$fn$;

SELECT allgres_private.sync_capability_index();
