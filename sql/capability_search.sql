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
      jsonb_build_object('is_system',a.is_system) metadata,a.is_active
    FROM allgres_private.agents a LEFT JOIN allgres_private.policies p USING(agent_id)
  LOOP
    PERFORM allgres_private.upsert_capability('agent',r.id,r.name,r.description,r.metadata,
      CASE WHEN r.is_active THEN 'published' ELSE 'disabled' END); v_count:=v_count+1;
  END LOOP;
  FOR r IN SELECT function_id id,name,description,
      jsonb_build_object('handler',handler,'param_schema',param_schema,'args_template',args_template,
        'build_status',build_status) metadata,is_active
    FROM allgres_private.functions
  LOOP
    PERFORM allgres_private.upsert_capability('function',r.id,r.name,r.description,r.metadata,
      CASE WHEN r.is_active AND (r.metadata->>'build_status') IN ('built',NULL) THEN 'published'
           WHEN r.is_active THEN 'draft' ELSE 'disabled' END); v_count:=v_count+1;
  END LOOP;
  FOR r IN SELECT procedure_id id,name,content description,
      jsonb_build_object('generation',generation,'build_status',build_status) metadata,is_active
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
    'average_latency_ms',round(avg(latency_ms),2)
  ) FROM allgres_private.capability_search_events
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
  SET outcome=CASE WHEN p_succeeded THEN 'succeeded' ELSE 'failed' END
  WHERE e.event_id=(
    SELECT e2.event_id FROM allgres_private.capability_search_events e2
    JOIN allgres_private.capability_index c ON c.capability_id=e2.selected_capability_id
    WHERE e2.task_id=p_task_id AND c.capability_type=p_type AND c.name=p_name
      AND e2.outcome='selected' ORDER BY e2.created_at DESC LIMIT 1
  );
END;
$fn$;

SELECT allgres_private.sync_capability_index();
