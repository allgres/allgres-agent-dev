-- Handing a decision point to the decision model, one point at a time (stage
-- 6, docs/delegation.md). Off by default and off for every point until a
-- person turns it on.
--
--   off      nothing is asked of the model.
--   observe  after a person decides, the model is asked the same question and
--            its answer is only compared; nobody sees it before deciding.
--   delegate a new approval or proposal is put to the model. A confident
--            answer decides it (kept as decided_by='laya', never a gold
--            label); a doubtful one, an error, a timeout, a stopped server,
--            or an answer the rules do not allow, leaves it with the person
--            exactly as if the model were not there.
--
-- The rules stay the boundary: the model may reject an approval, and may
-- approve one only when an agent is asking a person for judgement; it may
-- reject a proposal and never approve one; a write or physical tool still
-- needs a person's approval whatever the model says.

CREATE TABLE IF NOT EXISTS allgres_private.decision_delegation (
  point_key       text PRIMARY KEY CHECK (point_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  mode            text NOT NULL DEFAULT 'off' CHECK (mode IN ('off', 'observe', 'delegate')),
  connection_id   uuid REFERENCES allgres_private.api_connections(connection_id) ON DELETE SET NULL,
  checkpoint      text,
  min_confidence  numeric NOT NULL DEFAULT 0.80 CHECK (min_confidence BETWEEN 0 AND 1),
  scope_agent_ids uuid[],
  all_agents      boolean NOT NULL DEFAULT false,
  min_accuracy    numeric NOT NULL DEFAULT 0.80 CHECK (min_accuracy BETWEEN 0 AND 1),
  max_ece         numeric NOT NULL DEFAULT 0.10 CHECK (max_ece BETWEEN 0 AND 1),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- One switch over every point. Off: no point asks the model (what each point
-- was set to is kept, and everything waits for a person). The switch only
-- matters once a decision model is connected; with none, nothing is asked
-- whatever the switch says.
CREATE TABLE IF NOT EXISTS allgres_private.decision_delegation_switch (
  only_row   boolean PRIMARY KEY DEFAULT true CHECK (only_row),
  enabled    boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION allgres_private.delegation_enabled()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT COALESCE((SELECT enabled FROM allgres_private.decision_delegation_switch), true)
     AND EXISTS (SELECT 1 FROM allgres_private.api_connections WHERE kind = 'decision' AND is_enabled)
$fn$;

-- How a decision point is shown: where it comes from, its name and what it
-- decides. Whoever adds a point (approvals, rooms, teams, later functions)
-- may add a row; a point without one is shown under its source by a rule
-- below, so a new point never lacks a place in the list.
CREATE TABLE IF NOT EXISTS allgres_private.decision_point_meta (
  point_key   text PRIMARY KEY CHECK (point_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  category    text NOT NULL CHECK (btrim(category) <> ''),
  title       text NOT NULL CHECK (btrim(title) <> ''),
  description text NOT NULL DEFAULT ''
);
INSERT INTO allgres_private.decision_point_meta (point_key, category, title, description) VALUES
  ('approval_decision', 'Approvals', 'An agent asks to run or continue', 'A person is asked to approve or reject a request from an agent: a tool run, a limit raised, a step that needs a decision.'),
  ('proposal_decision', 'Approvals', 'An agent proposes a change', 'A person is asked to approve or reject a change an agent proposed: a new function, a setting, a document.'),
  ('room_task_confirmation', 'Rooms', 'A room task is confirmed', 'The lead of a room proposes a task; a person confirms it before it starts.')
ON CONFLICT (point_key) DO NOTHING;

CREATE OR REPLACE FUNCTION allgres_private.decision_point_info(p_point_key text)
RETURNS TABLE (category text, title text, description text)
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT m.category, m.title, m.description FROM allgres_private.decision_point_meta m WHERE m.point_key = p_point_key
  UNION ALL
  SELECT 'Teams', 'Work handed to a team', 'Who in the team takes work that someone else handed over, or that nobody does.'
   WHERE p_point_key LIKE 'team_assign_%' AND NOT EXISTS (SELECT 1 FROM allgres_private.decision_point_meta WHERE point_key = p_point_key)
  UNION ALL
  SELECT 'Other', p_point_key, ''
   WHERE p_point_key NOT LIKE 'team_assign_%' AND NOT EXISTS (SELECT 1 FROM allgres_private.decision_point_meta WHERE point_key = p_point_key)
$fn$;

CREATE TABLE IF NOT EXISTS allgres_private.decision_asks (
  ask_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  point_key         text NOT NULL,
  point_version     int NOT NULL,
  mode              text NOT NULL CHECK (mode IN ('observe', 'delegate')),
  source_kind       text NOT NULL,
  source_id         uuid NOT NULL,
  status            text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'in_flight', 'done', 'failed', 'lost')),
  url               text NOT NULL,
  allow_private     boolean NOT NULL DEFAULT false,
  connection_id     uuid REFERENCES allgres_private.api_connections(connection_id) ON DELETE SET NULL,
  request           jsonb NOT NULL,
  answer            text,
  answer_confidence numeric,
  low_confidence    boolean,
  outcome           text CHECK (outcome IN ('observed', 'applied', 'left_to_person', 'too_late', 'error')),
  note              text,
  human_answer      text,
  created_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (point_key, source_kind, source_id, mode)
);
CREATE INDEX IF NOT EXISTS decision_asks_queue_idx ON allgres_private.decision_asks (created_at) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS decision_asks_point_idx ON allgres_private.decision_asks (point_key, created_at DESC);

-- What laya-evals reported for a checkpoint, kept so that moving a point to
-- another checkpoint is a decision with evidence.
CREATE TABLE IF NOT EXISTS allgres_private.decision_eval_reports (
  report_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  point_key   text NOT NULL,
  checkpoint  text NOT NULL,
  n           int,
  accuracy    numeric,
  ece         numeric,
  report      jsonb NOT NULL,
  recorded_by uuid REFERENCES allgres_private.users(user_id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS allgres_private.decision_checkpoint_history (
  history_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  point_key  text NOT NULL,
  from_checkpoint text,
  to_checkpoint   text,
  report_id  uuid REFERENCES allgres_private.decision_eval_reports(report_id) ON DELETE SET NULL,
  changed_by uuid REFERENCES allgres_private.users(user_id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Points a model may decide for, and the answers it may apply.
CREATE OR REPLACE FUNCTION allgres_private.delegation_may_apply(p_point_key text, p_source_kind text, p_source_id uuid, p_answer text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  h allgres_private.human_approvals%ROWTYPE;
BEGIN
  -- NULL means allowed, otherwise the reason it is not.
  IF p_source_kind = 'approval' AND p_point_key = 'approval_decision' THEN
    SELECT * INTO h FROM allgres_private.human_approvals WHERE approval_id = p_source_id;
    IF NOT FOUND OR h.status <> 'pending' THEN RETURN 'it was already decided'; END IF;
    IF p_answer = 'reject' THEN RETURN NULL; END IF;
    IF p_answer = 'approve' AND (h.payload ? 'queue' OR h.payload ? 'ambiguous_outbound_call_id') THEN
      RETURN 'a tool run or an unknown outcome is only ever approved by a person';
    END IF;
    IF p_answer = 'approve' THEN RETURN NULL; END IF;
    RETURN 'the answer is not approve or reject';
  ELSIF p_source_kind = 'proposal' AND p_point_key = 'proposal_decision' THEN
    IF NOT EXISTS (SELECT 1 FROM allgres_private.change_proposals WHERE proposal_id = p_source_id AND status = 'pending') THEN
      RETURN 'it was already decided';
    END IF;
    IF p_answer = 'reject' THEN RETURN NULL; END IF;
    RETURN 'a proposal is only ever approved by a person';
  END IF;
  RETURN 'this kind of decision cannot be handed to the model';
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.decision_ask_enqueue(
  p_point_key text, p_mode text, p_source_kind text, p_source_id uuid, p_state text, p_human_answer text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  d allgres_private.decision_delegation%ROWTYPE;
  c allgres_private.api_connections%ROWTYPE;
  pt allgres_private.decision_points%ROWTYPE;
  v_url text;
  v_req jsonb;
  v_id uuid;
BEGIN
  IF NOT allgres_private.delegation_enabled() THEN RETURN NULL; END IF;
  SELECT * INTO d FROM allgres_private.decision_delegation WHERE point_key = p_point_key;
  IF NOT FOUND OR d.mode <> p_mode OR d.connection_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO c FROM allgres_private.api_connections WHERE connection_id = d.connection_id AND kind = 'decision' AND is_enabled;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO pt FROM allgres_private.decision_points WHERE point_key = p_point_key ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_url := rtrim(c.base_url, '/') || '/v1/systemone';
  IF allgres_private.check_outbound_url(v_url, c.allow_private_network) IS NOT NULL THEN RETURN NULL; END IF;
  v_req := jsonb_build_object(
    'state', COALESCE(p_state, ''),
    'questions', jsonb_build_object(p_point_key, jsonb_build_object(
      'type', pt.qtype, 'instructions', pt.instructions, 'criteria', pt.criteria)),
    'min_confidence', d.min_confidence);
  IF NULLIF(d.checkpoint, '') IS NOT NULL THEN
    v_req := v_req || jsonb_build_object('model', d.checkpoint);
  END IF;
  INSERT INTO allgres_private.decision_asks (point_key, point_version, mode, source_kind, source_id, url, allow_private, connection_id, request, human_answer)
  VALUES (p_point_key, pt.version, p_mode, p_source_kind, p_source_id, v_url, c.allow_private_network, c.connection_id, v_req, p_human_answer)
  ON CONFLICT (point_key, source_kind, source_id, mode) DO NOTHING
  RETURNING ask_id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- Called when a person's decision has just been kept: note it against any
-- earlier ask, and in observe mode ask the model now for comparison.
CREATE OR REPLACE FUNCTION allgres_private.decision_after_human_record(
  p_point_key text, p_state text, p_answer text, p_source_kind text, p_source_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF p_source_id IS NULL THEN RETURN; END IF;
  UPDATE allgres_private.decision_asks SET human_answer = p_answer, updated_at = now()
  WHERE point_key = p_point_key AND source_kind = p_source_kind AND source_id = p_source_id AND human_answer IS NULL;
  PERFORM allgres_private.decision_ask_enqueue(p_point_key, 'observe', p_source_kind, p_source_id, p_state, p_answer);
END;
$fn$;

-- A new approval or proposal in a delegated point is put to the model.
CREATE OR REPLACE FUNCTION allgres_private.decision_delegate_new()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  d allgres_private.decision_delegation%ROWTYPE;
  v_point text; v_kind text; v_id uuid; v_agent uuid; v_state text; v_fields text[];
BEGIN
  IF TG_TABLE_NAME = 'human_approvals' THEN
    v_point := 'approval_decision'; v_kind := 'approval'; v_id := NEW.approval_id;
    SELECT agent_id INTO v_agent FROM allgres_private.tasks WHERE task_id = NEW.task_id;
  ELSE
    v_point := 'proposal_decision'; v_kind := 'proposal'; v_id := NEW.proposal_id; v_agent := NEW.agent_id;
  END IF;
  IF NEW.status <> 'pending' THEN RETURN NEW; END IF;
  IF NOT allgres_private.delegation_enabled() THEN RETURN NEW; END IF;
  SELECT * INTO d FROM allgres_private.decision_delegation WHERE point_key = v_point AND mode = 'delegate';
  IF NOT FOUND THEN RETURN NEW; END IF;
  IF NOT d.all_agents AND NOT (v_agent = ANY (COALESCE(d.scope_agent_ids, ARRAY[]::uuid[]))) THEN RETURN NEW; END IF;
  SELECT state_fields INTO v_fields FROM allgres_private.decision_points WHERE point_key = v_point ORDER BY version DESC LIMIT 1;
  IF v_kind = 'approval' THEN
    v_state := allgres_private.approval_decision_state(v_id, v_fields);
  ELSE
    v_state := allgres_private.proposal_decision_state(v_id, v_fields);
  END IF;
  PERFORM allgres_private.decision_ask_enqueue(v_point, 'delegate', v_kind, v_id, v_state);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS decision_delegate_new_approval ON allgres_private.human_approvals;
CREATE TRIGGER decision_delegate_new_approval AFTER INSERT ON allgres_private.human_approvals
  FOR EACH ROW EXECUTE FUNCTION allgres_private.decision_delegate_new();
DROP TRIGGER IF EXISTS decision_delegate_new_proposal ON allgres_private.change_proposals;
CREATE TRIGGER decision_delegate_new_proposal AFTER INSERT ON allgres_private.change_proposals
  FOR EACH ROW EXECUTE FUNCTION allgres_private.decision_delegate_new();

-- The worker's side: take queued asks, send them, report back.
CREATE OR REPLACE FUNCTION allgres_public.fn_claim_decision_asks(p_limit int DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  v_out jsonb := '[]'::jsonb;
  v_n int := 0;
  v_headers jsonb;
  v_key text;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  UPDATE allgres_private.decision_asks
  SET status = 'lost', outcome = CASE WHEN mode = 'delegate' THEN 'left_to_person' ELSE 'error' END,
      note = 'no answer from the decision model in time', updated_at = now()
  WHERE status = 'in_flight' AND updated_at < now() - interval '2 minutes';
  FOR r IN
    SELECT a.ask_id, a.url, a.request, a.allow_private, a.connection_id, c.auth_kind, c.is_enabled
    FROM allgres_private.decision_asks a
    LEFT JOIN allgres_private.api_connections c ON c.connection_id = a.connection_id
    WHERE a.status = 'queued'
    ORDER BY a.created_at
    FOR UPDATE OF a SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 4), 16))
  LOOP
    IF r.is_enabled IS NOT TRUE THEN
      UPDATE allgres_private.decision_asks SET status = 'lost', outcome = 'error', note = 'connection disabled', updated_at = now() WHERE ask_id = r.ask_id;
      CONTINUE;
    END IF;
    UPDATE allgres_private.decision_asks SET status = 'in_flight', updated_at = now() WHERE ask_id = r.ask_id;
    v_headers := jsonb_build_object('accept', 'application/json', 'content-type', 'application/json');
    IF r.auth_kind <> 'none' THEN
      v_key := COALESCE(allgres_private.connection_secret(r.connection_id), '');
      IF v_key <> '' THEN
        v_headers := v_headers || jsonb_build_object(
          allgres_private.conn_header_kind(r.auth_kind),
          CASE WHEN r.auth_kind = 'x-api-key' THEN v_key ELSE 'Bearer ' || v_key END);
      END IF;
    END IF;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'call_id', r.ask_id, 'kind', 'decision_ask', 'method', 'POST', 'url', r.url,
      'headers', v_headers, 'body', r.request, 'allow_private', r.allow_private));
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('count', v_n, 'calls', v_out);
END;
$fn$;

-- The model's reading of the reply. The answer is the label under "choice"
-- (or answer/label/value), found under "answers" or at the top level, and
-- confidence is gated here on answer_confidence (or the chosen label's
-- probability), whatever flag the server sets.
CREATE OR REPLACE FUNCTION allgres_private.decision_parse_answer(p_body jsonb, p_point_key text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  v_node jsonb;
  v_label text;
  v_conf numeric;
  v_flag boolean;
BEGIN
  IF jsonb_typeof(p_body) <> 'object' THEN RETURN NULL; END IF;
  v_node := COALESCE(p_body->'answers'->p_point_key, p_body->p_point_key);
  IF v_node IS NULL OR jsonb_typeof(v_node) <> 'object' THEN RETURN NULL; END IF;
  v_label := COALESCE(v_node->>'choice', v_node->>'answer', v_node->>'label', v_node->>'value');
  -- answer_confidence is the probability of the answer given (laya-serve's own
  -- advice for gating). With LAYA_JEV_STRICT it is left out, so the probability
  -- of the chosen label stands in. "confidence" (normalised entropy) is never
  -- used: a missing figure counts as not sure.
  BEGIN
    v_conf := COALESCE((v_node->>'answer_confidence')::numeric, (v_node->'probabilities'->>v_label)::numeric);
  EXCEPTION WHEN others THEN v_conf := NULL; END;
  v_flag := COALESCE((v_node->>'low_confidence')::boolean, false) OR COALESCE(v_node->>'abstention', '') = 'abstained';
  RETURN jsonb_build_object('answer', v_label, 'confidence', v_conf, 'flagged_low', v_flag);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_complete_decision_ask(p_call_id uuid, p_status int, p_body text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  a allgres_private.decision_asks%ROWTYPE;
  d allgres_private.decision_delegation%ROWTYPE;
  v_body jsonb;
  v_parsed jsonb;
  v_answer text; v_conf numeric; v_low boolean;
  v_why text;
  v_outcome text; v_note text;
  v_crit jsonb;
BEGIN
  SELECT * INTO a FROM allgres_private.decision_asks WHERE ask_id = p_call_id AND status = 'in_flight' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
  SELECT * INTO d FROM allgres_private.decision_delegation WHERE point_key = a.point_key;
  BEGIN v_body := p_body::jsonb; EXCEPTION WHEN others THEN v_body := NULL; END;
  IF p_status NOT BETWEEN 200 AND 299 OR v_body IS NULL THEN
    UPDATE allgres_private.decision_asks
    SET status = 'failed', outcome = CASE WHEN mode = 'delegate' THEN 'left_to_person' ELSE 'error' END,
        note = CASE WHEN p_status NOT BETWEEN 200 AND 299 THEN 'the server answered ' || p_status ELSE 'the reply was not JSON' END,
        updated_at = now()
    WHERE ask_id = p_call_id;
    RETURN jsonb_build_object('ok', true, 'outcome', 'error');
  END IF;
  v_parsed := allgres_private.decision_parse_answer(v_body, a.point_key);
  v_answer := v_parsed->>'answer';
  v_conf := (v_parsed->>'confidence')::numeric;
  SELECT criteria INTO v_crit FROM allgres_private.decision_points WHERE point_key = a.point_key AND version = a.point_version;
  IF v_answer IS NULL OR v_crit IS NULL OR NOT (v_crit ? v_answer) THEN
    UPDATE allgres_private.decision_asks
    SET status = 'failed', outcome = CASE WHEN mode = 'delegate' THEN 'left_to_person' ELSE 'error' END,
        note = 'the reply carried no answer this question offers', updated_at = now()
    WHERE ask_id = p_call_id;
    RETURN jsonb_build_object('ok', true, 'outcome', 'error');
  END IF;
  v_low := COALESCE((v_parsed->>'flagged_low')::boolean, false) OR v_conf IS NULL OR v_conf < COALESCE(d.min_confidence, 0.8);
  v_outcome := 'observed';
  IF a.mode = 'delegate' THEN
    IF d.mode IS DISTINCT FROM 'delegate' THEN
      v_outcome := 'left_to_person'; v_note := 'delegation was switched off before the answer came';
    ELSIF v_low THEN
      v_outcome := 'left_to_person'; v_note := 'the model was not confident enough';
    ELSE
      v_why := allgres_private.delegation_may_apply(a.point_key, a.source_kind, a.source_id, v_answer);
      IF v_why IS NOT NULL THEN
        v_outcome := CASE WHEN v_why = 'it was already decided' THEN 'too_late' ELSE 'left_to_person' END;
        v_note := v_why;
      ELSE
        BEGIN
          PERFORM set_config('allgres.laya_decision', a.source_id::text, true);
          IF a.source_kind = 'approval' THEN
            PERFORM allgres_public.fn_decide_approval(a.source_id, v_answer = 'approve',
              'Decided by the decision model (confidence ' || round(v_conf, 2) || ').');
          ELSE
            PERFORM allgres_public.fn_decide_proposal(a.source_id, v_answer = 'approve',
              'Decided by the decision model (confidence ' || round(v_conf, 2) || ').');
          END IF;
          v_outcome := 'applied';
        EXCEPTION WHEN OTHERS THEN
          v_outcome := 'left_to_person'; v_note := 'it could not be applied: ' || left(SQLERRM, 200);
        END;
        PERFORM set_config('allgres.laya_decision', '', true);
      END IF;
    END IF;
  END IF;
  UPDATE allgres_private.decision_asks
  SET status = 'done', answer = v_answer, answer_confidence = v_conf, low_confidence = v_low,
      outcome = v_outcome, note = v_note, updated_at = now()
  WHERE ask_id = p_call_id;
  RETURN jsonb_build_object('ok', true, 'outcome', v_outcome);
END;
$fn$;

-- ---- Settings, evidence, and the way back --------------------------------

-- Agreement between the model and people on what was observed.
CREATE OR REPLACE FUNCTION allgres_private.delegation_observed(p_point_key text)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'asked', count(*),
    'compared', count(*) FILTER (WHERE status = 'done' AND human_answer IS NOT NULL),
    'agreed', count(*) FILTER (WHERE status = 'done' AND human_answer IS NOT NULL AND answer = human_answer),
    'low_confidence', count(*) FILTER (WHERE low_confidence),
    'errors', count(*) FILTER (WHERE outcome = 'error' OR status IN ('failed', 'lost')),
    'applied', count(*) FILTER (WHERE outcome = 'applied'),
    'left_to_person', count(*) FILTER (WHERE outcome = 'left_to_person'))
  FROM allgres_private.decision_asks WHERE point_key = p_point_key
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_decision_delegation_set(
  p_point_key text, p_mode text, p_connection_id uuid DEFAULT NULL, p_checkpoint text DEFAULT NULL,
  p_min_confidence numeric DEFAULT NULL, p_scope_agent_ids uuid[] DEFAULT NULL, p_all_agents boolean DEFAULT false,
  p_min_accuracy numeric DEFAULT NULL, p_max_ece numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  cur allgres_private.decision_delegation%ROWTYPE;
  v_obs jsonb;
  v_conn uuid;
  v_conf numeric;
  v_scope uuid[];
  v_all boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.decision_points WHERE point_key = p_point_key) THEN
    RAISE EXCEPTION 'decision point not found' USING ERRCODE = 'P0001';
  END IF;
  IF p_mode NOT IN ('off', 'observe', 'delegate') THEN
    RAISE EXCEPTION 'the mode is off, observe, or delegate' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO cur FROM allgres_private.decision_delegation WHERE point_key = p_point_key;
  v_conn := COALESCE(p_connection_id, cur.connection_id);
  v_conf := COALESCE(p_min_confidence, cur.min_confidence, 0.80);
  v_scope := COALESCE(p_scope_agent_ids, cur.scope_agent_ids);
  v_all := COALESCE(p_all_agents, false) OR (p_scope_agent_ids IS NULL AND COALESCE(cur.all_agents, false));
  IF p_mode <> 'off' THEN
    IF v_conn IS NULL OR NOT EXISTS (SELECT 1 FROM allgres_private.api_connections WHERE connection_id = v_conn AND kind = 'decision' AND is_enabled) THEN
      RAISE EXCEPTION 'connect a decision model first and pick it' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF p_mode = 'delegate' THEN
    IF p_point_key NOT IN ('approval_decision', 'proposal_decision') THEN
      RAISE EXCEPTION 'only approvals and proposals can be handed to the model; observe this one instead' USING ERRCODE = 'P0001';
    END IF;
    v_obs := allgres_private.delegation_observed(p_point_key);
    IF (v_obs->>'compared')::int < 10
       OR (v_obs->>'agreed')::numeric / NULLIF((v_obs->>'compared')::numeric, 0) < COALESCE(p_min_accuracy, cur.min_accuracy, 0.80) THEN
      RAISE EXCEPTION 'observe first: at least 10 decisions compared with % percent agreement (now % compared, % agreed)',
        round(COALESCE(p_min_accuracy, cur.min_accuracy, 0.80) * 100), v_obs->>'compared', v_obs->>'agreed' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_all AND cardinality(COALESCE(v_scope, ARRAY[]::uuid[])) = 0 THEN
      RAISE EXCEPTION 'pick the agents whose decisions go to the model, or choose all agents on purpose' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  INSERT INTO allgres_private.decision_delegation
    (point_key, mode, connection_id, checkpoint, min_confidence, scope_agent_ids, all_agents, min_accuracy, max_ece, updated_at)
  VALUES (p_point_key, p_mode, v_conn, NULLIF(COALESCE(p_checkpoint, cur.checkpoint), ''), v_conf, v_scope, v_all,
          COALESCE(p_min_accuracy, cur.min_accuracy, 0.80), COALESCE(p_max_ece, cur.max_ece, 0.10), now())
  ON CONFLICT (point_key) DO UPDATE SET
    mode = EXCLUDED.mode, connection_id = EXCLUDED.connection_id, checkpoint = EXCLUDED.checkpoint,
    min_confidence = EXCLUDED.min_confidence, scope_agent_ids = EXCLUDED.scope_agent_ids, all_agents = EXCLUDED.all_agents,
    min_accuracy = EXCLUDED.min_accuracy, max_ece = EXCLUDED.max_ece, updated_at = now();
  -- Going back to off or observe stops asks that have not been sent.
  IF p_mode <> 'delegate' THEN
    UPDATE allgres_private.decision_asks SET status = 'lost', outcome = 'left_to_person', note = 'delegation was switched off', updated_at = now()
    WHERE point_key = p_point_key AND mode = 'delegate' AND status IN ('queued', 'in_flight');
  END IF;
  IF p_mode = 'off' THEN
    UPDATE allgres_private.decision_asks SET status = 'lost', note = 'observation was switched off', updated_at = now()
    WHERE point_key = p_point_key AND status = 'queued';
  END IF;
  PERFORM allgres_private.audit('decision_delegation.set', jsonb_build_object(
    'point_key', p_point_key, 'mode', p_mode, 'previous', cur.mode, 'connection_id', v_conn,
    'min_confidence', v_conf, 'all_agents', v_all, 'scope', v_scope));
  RETURN jsonb_build_object('ok', true, 'mode', p_mode);
END;
$fn$;

-- The way back in one step: every point to off.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_delegation_off_all()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  v_n int;
BEGIN
  UPDATE allgres_private.decision_delegation SET mode = 'off', updated_at = now() WHERE mode <> 'off';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE allgres_private.decision_asks SET status = 'lost', outcome = 'left_to_person', note = 'delegation was switched off', updated_at = now()
  WHERE status IN ('queued', 'in_flight') AND mode = 'delegate';
  PERFORM allgres_private.audit('decision_delegation.off_all', jsonb_build_object('points', v_n));
  RETURN jsonb_build_object('ok', true, 'points', v_n);
END;
$fn$;

-- The one switch. Turning it off drops what has not been sent; every point
-- keeps its setting, so turning it on again restores them.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_delegation_switch(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
BEGIN
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'enabled must be true or false' USING ERRCODE = 'P0001';
  END IF;
  IF p_enabled AND NOT EXISTS (SELECT 1 FROM allgres_private.api_connections WHERE kind = 'decision' AND is_enabled) THEN
    RAISE EXCEPTION 'connect a decision model first' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.decision_delegation_switch (only_row, enabled) VALUES (true, p_enabled)
  ON CONFLICT (only_row) DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now();
  IF NOT p_enabled THEN
    UPDATE allgres_private.decision_asks SET status = 'lost', outcome = 'left_to_person', note = 'the decision model was switched off', updated_at = now()
    WHERE status IN ('queued', 'in_flight');
  END IF;
  PERFORM allgres_private.audit('decision_delegation.switch', jsonb_build_object('enabled', p_enabled));
  RETURN jsonb_build_object('ok', true, 'enabled', p_enabled);
END;
$fn$;

-- Takes the numbers out of a laya-evals JSON report and keeps the whole thing.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_eval_record(p_token text, p_point_key text, p_checkpoint text, p_report jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE := allgres_private.session_user(p_token);
  v_acc numeric; v_ece numeric; v_n int; v_id uuid;
  v_src jsonb := COALESCE(p_report->'metrics', p_report->'summary', p_report);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.decision_points WHERE point_key = p_point_key) THEN
    RAISE EXCEPTION 'decision point not found' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(btrim(p_checkpoint), '') IS NULL OR jsonb_typeof(p_report) <> 'object' THEN
    RAISE EXCEPTION 'give the checkpoint name and the report as a JSON object' USING ERRCODE = 'P0001';
  END IF;
  BEGIN v_acc := COALESCE((v_src->>'accuracy')::numeric, (v_src->>'acc')::numeric); EXCEPTION WHEN others THEN v_acc := NULL; END;
  BEGIN v_ece := COALESCE((v_src->>'ece')::numeric, (v_src->>'ECE')::numeric); EXCEPTION WHEN others THEN v_ece := NULL; END;
  BEGIN v_n := COALESCE((v_src->>'n')::int, (v_src->>'count')::int, (v_src->>'samples')::int); EXCEPTION WHEN others THEN v_n := NULL; END;
  IF v_acc IS NULL THEN
    RAISE EXCEPTION 'the report has no accuracy' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.decision_eval_reports (point_key, checkpoint, n, accuracy, ece, report, recorded_by)
  VALUES (p_point_key, btrim(p_checkpoint), v_n, v_acc, v_ece, p_report, u.user_id) RETURNING report_id INTO v_id;
  PERFORM allgres_private.audit('decision_delegation.eval_record', jsonb_build_object('report_id', v_id, 'point_key', p_point_key, 'checkpoint', btrim(p_checkpoint)));
  RETURN jsonb_build_object('ok', true, 'report_id', v_id, 'accuracy', v_acc, 'ece', v_ece);
END;
$fn$;

-- Moving a point to another checkpoint needs a report for that checkpoint
-- that meets the point's own bar.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_checkpoint_switch(p_token text, p_point_key text, p_report_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE := allgres_private.session_user(p_token);
  d allgres_private.decision_delegation%ROWTYPE;
  r allgres_private.decision_eval_reports%ROWTYPE;
BEGIN
  SELECT * INTO d FROM allgres_private.decision_delegation WHERE point_key = p_point_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'connect a decision model to this point first' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO r FROM allgres_private.decision_eval_reports WHERE report_id = p_report_id AND point_key = p_point_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found for this point' USING ERRCODE = 'P0001'; END IF;
  IF r.accuracy < d.min_accuracy THEN
    RAISE EXCEPTION 'accuracy % is below the bar of %', r.accuracy, d.min_accuracy USING ERRCODE = 'P0001';
  END IF;
  IF r.ece IS NOT NULL AND r.ece > d.max_ece THEN
    RAISE EXCEPTION 'calibration error % is above the limit of %', r.ece, d.max_ece USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.decision_checkpoint_history (point_key, from_checkpoint, to_checkpoint, report_id, changed_by)
  VALUES (p_point_key, d.checkpoint, r.checkpoint, r.report_id, u.user_id);
  UPDATE allgres_private.decision_delegation SET checkpoint = r.checkpoint, updated_at = now() WHERE point_key = p_point_key;
  PERFORM allgres_private.audit('decision_delegation.checkpoint_switch', jsonb_build_object(
    'point_key', p_point_key, 'from', d.checkpoint, 'to', r.checkpoint, 'report_id', r.report_id));
  RETURN jsonb_build_object('ok', true, 'checkpoint', r.checkpoint);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_decision_delegation_overview()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'enabled', COALESCE((SELECT enabled FROM allgres_private.decision_delegation_switch), true),
    'has_model', EXISTS (SELECT 1 FROM allgres_private.api_connections WHERE kind = 'decision' AND is_enabled),
    'active', allgres_private.delegation_enabled(),
    'points', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'point_key', p.point_key, 'category', i.category, 'title', i.title, 'description', i.description, 'instructions', p.instructions, 'delegable', p.point_key IN ('approval_decision', 'proposal_decision'),
        'mode', COALESCE(d.mode, 'off'), 'connection_id', d.connection_id, 'connection', c.name, 'checkpoint', d.checkpoint,
        'min_confidence', COALESCE(d.min_confidence, 0.80), 'all_agents', COALESCE(d.all_agents, false),
        'scope_agent_ids', COALESCE(to_jsonb(d.scope_agent_ids), '[]'::jsonb),
        'min_accuracy', COALESCE(d.min_accuracy, 0.80), 'max_ece', COALESCE(d.max_ece, 0.10),
        'observed', allgres_private.delegation_observed(p.point_key),
        'reports', COALESCE((SELECT jsonb_agg(jsonb_build_object('report_id', r.report_id, 'checkpoint', r.checkpoint,
            'accuracy', r.accuracy, 'ece', r.ece, 'n', r.n, 'created_at', r.created_at) ORDER BY r.created_at DESC)
          FROM allgres_private.decision_eval_reports r WHERE r.point_key = p.point_key), '[]'::jsonb)
      ) ORDER BY i.category, i.title, p.point_key)
      FROM allgres_private.decision_points p
      LEFT JOIN allgres_private.decision_delegation d ON d.point_key = p.point_key
      LEFT JOIN allgres_private.api_connections c ON c.connection_id = d.connection_id
      CROSS JOIN LATERAL allgres_private.decision_point_info(p.point_key) i
      WHERE p.version = (SELECT max(version) FROM allgres_private.decision_points WHERE point_key = p.point_key)
        AND p.point_key NOT LIKE 'team_assign_%'), '[]'::jsonb),
    'recent', COALESCE((SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC) FROM (
        SELECT jsonb_build_object('point_key', a.point_key, 'mode', a.mode, 'status', a.status, 'outcome', a.outcome,
          'answer', a.answer, 'human_answer', a.human_answer, 'confidence', a.answer_confidence, 'note', a.note,
          'created_at', a.created_at) AS x
        FROM allgres_private.decision_asks a ORDER BY a.created_at DESC LIMIT 20) q), '[]'::jsonb))
$fn$;
