-- Rules a person writes for a decision point (docs/decision-rules.md). They
-- are data, not code: an ordered list of branches, each a condition and an
-- outcome, read by one fixed evaluator. For a new approval or proposal the
-- order is   rules -> the decision model -> a person.
--
--   approve / reject   the rule decides (kept as decided_by = 'rule', never a
--                      gold label)
--   ask the model      stop reading rules; the model is asked, as without rules
--   send to a person   stop reading rules; nobody but a person decides
--   (no rule matches)  as if there were no rules
--
-- A rule that approves is the sharpest tool here, so it is held to more: it
-- must name who or what it is about (an agent, an action, a resource, a kind
-- of proposal), it is saved only with a confirmation, and it can be tried on
-- past decisions first. An unknown outcome of an outbound call is never
-- approved by a rule.

CREATE TABLE IF NOT EXISTS allgres_private.decision_rules (
  rule_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  point_key   text NOT NULL CHECK (point_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  position    int NOT NULL DEFAULT 0,
  name        text NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 80),
  conditions  jsonb NOT NULL CHECK (jsonb_typeof(conditions) = 'object'),
  outcome     text NOT NULL CHECK (outcome IN ('answer', 'ask_model', 'to_human')),
  answer      text,
  is_enabled  boolean NOT NULL DEFAULT true,
  created_by  uuid REFERENCES allgres_private.users(user_id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CHECK ((outcome = 'answer') = (answer IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS decision_rules_point_idx ON allgres_private.decision_rules (point_key, position);

-- Each new item is read against the rules once; this is that record.
CREATE TABLE IF NOT EXISTS allgres_private.decision_rule_checks (
  source_kind text NOT NULL,
  source_id   uuid NOT NULL,
  point_key   text NOT NULL,
  result      text NOT NULL,
  rule_id     uuid,
  checked_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source_kind, source_id)
);

-- A function or procedure may declare a decision point of its own: a person is
-- asked before it runs, and that question is a named point in the list with its
-- own rules, instead of the general "an agent asks to run" point.
CREATE TABLE IF NOT EXISTS allgres_private.declared_decision_points (
  point_key  text PRIMARY KEY CHECK (point_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  kind       text NOT NULL CHECK (kind IN ('function', 'procedure')),
  ref_id     uuid NOT NULL UNIQUE,
  created_by uuid REFERENCES allgres_private.users(user_id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Which point an approval belongs to: the one its function or procedure
-- declared (stamped on the request when it was made), else the general one.
CREATE OR REPLACE FUNCTION allgres_private.decision_point_of_payload(p_payload jsonb)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT COALESCE((SELECT d.point_key FROM allgres_private.declared_decision_points d
                   WHERE d.point_key = p_payload->>'decision_point'), 'approval_decision')
$fn$;

-- Points whose items are approvals of an agent's request (the general one and every declared one).
CREATE OR REPLACE FUNCTION allgres_private.decision_point_is_approval(p_point_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT p_point_key = 'approval_decision' OR EXISTS (SELECT 1 FROM allgres_private.declared_decision_points WHERE point_key = p_point_key)
$fn$;

-- Points that rules can be written for.
CREATE OR REPLACE FUNCTION allgres_private.decision_rule_point_ok(p_point_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT p_point_key IN ('proposal_decision', 'room_task_confirmation') OR allgres_private.decision_point_is_approval(p_point_key)
$fn$;

-- What a condition may look at, per point. Never a secret or a body.
CREATE OR REPLACE FUNCTION allgres_private.decision_rule_fields(p_point_key text)
RETURNS text[]
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT CASE
    WHEN allgres_private.decision_point_is_approval(p_point_key) THEN ARRAY['agent', 'approval_type', 'action', 'resource', 'reason', 'goal']
    WHEN p_point_key = 'proposal_decision' THEN ARRAY['agent', 'proposal_kind', 'target_agent', 'reason']
    WHEN p_point_key = 'room_task_confirmation' THEN ARRAY['room', 'proposed_by', 'assignee', 'role', 'goal']
    ELSE ARRAY[]::text[] END
$fn$;

-- The fields that say who or what a rule is about; a rule that approves needs one.
CREATE OR REPLACE FUNCTION allgres_private.decision_rule_narrowing_fields(p_point_key text)
RETURNS text[]
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT CASE
    WHEN allgres_private.decision_point_is_approval(p_point_key) THEN ARRAY['agent', 'action', 'resource']
    WHEN p_point_key = 'proposal_decision' THEN ARRAY['agent', 'proposal_kind']
    ELSE ARRAY[]::text[] END
$fn$;

-- The facts of one item, as the same fields the decision record would keep.
CREATE OR REPLACE FUNCTION allgres_private.decision_rule_facts(p_point_key text, p_kind text, p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  h allgres_private.human_approvals%ROWTYPE;
  cp allgres_private.change_proposals%ROWTYPE;
  v_agent text; v_goal text; v_target text;
  rp allgres_private.room_proposals%ROWTYPE;
  v_room text; v_by text; v_assignee text; v_role text;
BEGIN
  IF p_kind = 'approval' AND allgres_private.decision_point_is_approval(p_point_key) THEN
    SELECT * INTO h FROM allgres_private.human_approvals WHERE approval_id = p_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT a.name, s.goal INTO v_agent, v_goal
    FROM allgres_private.tasks t
    JOIN allgres_private.agents a ON a.agent_id = t.agent_id
    JOIN allgres_private.sessions s ON s.session_id = t.session_id
    WHERE t.task_id = h.task_id;
    RETURN jsonb_strip_nulls(jsonb_build_object(
      'agent', v_agent,
      'approval_type', CASE WHEN h.payload ? 'queue' THEN 'execution'
                            WHEN h.payload ? 'ambiguous_outbound_call_id' THEN 'outbound_unknown'
                            ELSE 'await_human' END,
      'action', CASE WHEN jsonb_typeof(h.payload->'action') = 'string' THEN left(h.payload->>'action', 120) END,
      'resource', CASE WHEN jsonb_typeof(h.payload->'resource') = 'string'
                       THEN left(regexp_replace(h.payload->>'resource', '[?#].*$', ''), 200) END,
      'reason', CASE WHEN jsonb_typeof(h.payload->'reason') = 'string' THEN left(h.payload->>'reason', 600) END,
      'goal', left(v_goal, 600)));
  ELSIF p_point_key = 'room_task_confirmation' AND p_kind = 'room_proposal' THEN
    SELECT * INTO rp FROM allgres_private.room_proposals WHERE proposal_id = p_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT name INTO v_room FROM allgres_private.rooms WHERE room_id = rp.room_id;
    SELECT name INTO v_by FROM allgres_private.agents WHERE agent_id = rp.proposed_by_agent;
    SELECT name INTO v_assignee FROM allgres_private.agents WHERE agent_id = rp.assignee_agent_id;
    SELECT ro.name INTO v_role FROM allgres_private.room_members m JOIN allgres_private.room_roles ro USING (role_id)
    WHERE m.room_id = rp.room_id AND m.agent_id = rp.assignee_agent_id;
    RETURN jsonb_strip_nulls(jsonb_build_object('room', v_room, 'proposed_by', v_by, 'assignee', v_assignee, 'role', v_role,
      'goal', left(rp.goal, 600)));
  ELSIF p_point_key = 'proposal_decision' AND p_kind = 'proposal' THEN
    SELECT * INTO cp FROM allgres_private.change_proposals WHERE proposal_id = p_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT name INTO v_agent FROM allgres_private.agents WHERE agent_id = cp.agent_id;
    SELECT name INTO v_target FROM allgres_private.agents WHERE agent_id = cp.target_agent_id;
    RETURN jsonb_strip_nulls(jsonb_build_object(
      'agent', v_agent, 'proposal_kind', cp.kind, 'target_agent', v_target, 'reason', left(cp.reason, 600)));
  END IF;
  RETURN NULL;
END;
$fn$;

-- One condition. {"all": [..]} and {"any": [..]} nest; a leaf is
-- {"field": .., "op": eq|ne|in|starts_with|contains, "value": text (a list of text for in)}.
-- {} is "always". A missing fact never matches a leaf (except ne).
CREATE OR REPLACE FUNCTION allgres_private.decision_cond_eval(c jsonb, facts jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  e jsonb; v_have text; v_val jsonb;
BEGIN
  IF c = '{}'::jsonb THEN RETURN true; END IF;
  IF c ? 'all' THEN
    FOR e IN SELECT x FROM jsonb_array_elements(c->'all') x LOOP
      IF NOT allgres_private.decision_cond_eval(e, facts) THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
  ELSIF c ? 'any' THEN
    FOR e IN SELECT x FROM jsonb_array_elements(c->'any') x LOOP
      IF allgres_private.decision_cond_eval(e, facts) THEN RETURN true; END IF;
    END LOOP;
    RETURN false;
  END IF;
  v_have := facts->>(c->>'field');
  v_val := c->'value';
  RETURN CASE c->>'op'
    WHEN 'eq' THEN v_have IS NOT NULL AND v_have = (v_val #>> '{}')
    WHEN 'ne' THEN v_have IS DISTINCT FROM (v_val #>> '{}')
    WHEN 'in' THEN v_have IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_val) x WHERE x = v_have)
    WHEN 'starts_with' THEN v_have IS NOT NULL AND left(v_have, length(v_val #>> '{}')) = (v_val #>> '{}')
    WHEN 'contains' THEN v_have IS NOT NULL AND position((v_val #>> '{}') IN v_have) > 0
    ELSE false END;
END;
$fn$;

-- Refuses anything the evaluator does not read exactly: unknown fields or
-- operators, wrong value types, deep or large conditions.
CREATE OR REPLACE FUNCTION allgres_private.decision_cond_check(c jsonb, p_fields text[], p_depth int DEFAULT 0)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  e jsonb; v_key text;
BEGIN
  IF jsonb_typeof(c) <> 'object' THEN
    RAISE EXCEPTION 'a condition is an object' USING ERRCODE = '22023';
  END IF;
  IF p_depth > 3 THEN
    RAISE EXCEPTION 'conditions nest at most 3 deep' USING ERRCODE = '22023';
  END IF;
  IF p_depth = 0 AND length(c::text) > 4000 THEN
    RAISE EXCEPTION 'the condition is too large' USING ERRCODE = '22023';
  END IF;
  IF c = '{}'::jsonb THEN RETURN; END IF;
  IF (c ? 'all') OR (c ? 'any') THEN
    v_key := CASE WHEN c ? 'all' THEN 'all' ELSE 'any' END;
    IF (SELECT count(*) FROM jsonb_object_keys(c)) <> 1 OR jsonb_typeof(c->v_key) <> 'array'
       OR jsonb_array_length(c->v_key) NOT BETWEEN 1 AND 20 THEN
      RAISE EXCEPTION 'all / any is a list of 1 to 20 conditions' USING ERRCODE = '22023';
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(c->v_key) x LOOP
      IF e = '{}'::jsonb THEN RAISE EXCEPTION 'a condition in a list cannot be empty' USING ERRCODE = '22023'; END IF;
      PERFORM allgres_private.decision_cond_check(e, p_fields, p_depth + 1);
    END LOOP;
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(c) k WHERE k NOT IN ('field', 'op', 'value')) THEN
    RAISE EXCEPTION 'a condition has field, op and value' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(c->'field') <> 'string' OR NOT ((c->>'field') = ANY (p_fields)) THEN
    RAISE EXCEPTION 'unknown field "%"; use one of: %', c->>'field', array_to_string(p_fields, ', ') USING ERRCODE = '22023';
  END IF;
  IF c->>'op' NOT IN ('eq', 'ne', 'in', 'starts_with', 'contains') THEN
    RAISE EXCEPTION 'op is eq, ne, in, starts_with or contains' USING ERRCODE = '22023';
  END IF;
  IF c->>'op' = 'in' THEN
    IF jsonb_typeof(c->'value') <> 'array' OR jsonb_array_length(c->'value') NOT BETWEEN 1 AND 50
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(c->'value') x WHERE jsonb_typeof(x) <> 'string' OR length(x #>> '{}') > 200) THEN
      RAISE EXCEPTION 'in takes a list of 1 to 50 texts' USING ERRCODE = '22023';
    END IF;
  ELSIF jsonb_typeof(c->'value') <> 'string' OR length(c->>'value') NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'the value is a text of 1 to 200 characters' USING ERRCODE = '22023';
  END IF;
END;
$fn$;

-- Does the condition name who or what it is about? Only an "all" can: an
-- "any" would let the other branch widen it.
CREATE OR REPLACE FUNCTION allgres_private.decision_cond_narrows(c jsonb, p_point_key text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT c ? 'all' AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(c->'all') x
    WHERE (x->>'field') = ANY (allgres_private.decision_rule_narrowing_fields(p_point_key))
      AND x->>'op' IN ('eq', 'in', 'starts_with'))
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.decision_rules_exist(p_point_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT EXISTS (SELECT 1 FROM allgres_private.decision_rules WHERE point_key = p_point_key AND is_enabled)
$fn$;

-- May a rule give this answer to these facts? An unknown outcome of an
-- outbound call is only ever approved by a person.
CREATE OR REPLACE FUNCTION allgres_private.decision_rule_may_answer(p_point_key text, p_facts jsonb, p_answer text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT NOT (p_point_key <> 'proposal_decision' AND p_point_key <> 'room_task_confirmation'
              AND p_answer = 'approve' AND p_facts->>'approval_type' = 'outbound_unknown')
     AND NOT (p_point_key = 'room_task_confirmation' AND p_answer = 'confirm')
$fn$;

-- One new item against the rules. Returns what happened: applied, to_human,
-- ask_model, none (no rule matched) or error.
CREATE OR REPLACE FUNCTION allgres_private.decision_rules_apply_one(p_point_key text, p_kind text, p_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r allgres_private.decision_rules%ROWTYPE;
  v_facts jsonb;
  v_result text := 'none';
  v_rule uuid;
BEGIN
  v_facts := allgres_private.decision_rule_facts(p_point_key, p_kind, p_id);
  IF v_facts IS NOT NULL THEN
    FOR r IN SELECT * FROM allgres_private.decision_rules
             WHERE point_key = p_point_key AND is_enabled ORDER BY position, created_at LOOP
      IF NOT allgres_private.decision_cond_eval(r.conditions, v_facts) THEN CONTINUE; END IF;
      IF r.outcome = 'answer' THEN
        IF NOT allgres_private.decision_rule_may_answer(p_point_key, v_facts, r.answer) THEN CONTINUE; END IF;
        BEGIN
          PERFORM set_config('allgres.rule_decision', p_id::text, true);
          PERFORM set_config('allgres.rule_id', r.rule_id::text, true);
          IF p_kind = 'approval' THEN
            PERFORM allgres_public.fn_decide_approval(p_id, r.answer = 'approve', 'Decided by the rule "' || r.name || '".');
          ELSIF p_kind = 'room_proposal' THEN
            PERFORM allgres_private.room_proposal_decline_by_rule(p_id, r.rule_id, r.name);
          ELSE
            PERFORM allgres_public.fn_decide_proposal(p_id, r.answer = 'approve', 'Decided by the rule "' || r.name || '".');
          END IF;
          v_result := 'applied'; v_rule := r.rule_id;
        EXCEPTION WHEN OTHERS THEN
          v_result := 'error'; v_rule := r.rule_id;
        END;
        PERFORM set_config('allgres.rule_decision', '', true);
        PERFORM set_config('allgres.rule_id', '', true);
      ELSE
        v_result := CASE r.outcome WHEN 'to_human' THEN 'to_human' ELSE 'ask_model' END; v_rule := r.rule_id;
      END IF;
      EXIT;
    END LOOP;
  END IF;
  INSERT INTO allgres_private.decision_rule_checks (source_kind, source_id, point_key, result, rule_id)
  VALUES (p_kind, p_id, p_point_key, v_result, v_rule)
  ON CONFLICT (source_kind, source_id) DO NOTHING;
  RETURN v_result;
END;
$fn$;

-- Called every tick by the worker (from fn_claim_decision_asks): reads each
-- pending item that has not been read yet, then hands what the rules leave to
-- the decision model.
CREATE OR REPLACE FUNCTION allgres_private.decision_rules_sweep()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record; v_res text; v_n int := 0; v_agent uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.decision_rules WHERE is_enabled) THEN RETURN 0; END IF;
  FOR r IN
    SELECT allgres_private.decision_point_of_payload(h.payload) AS point, 'approval' AS kind, h.approval_id AS id
    FROM allgres_private.human_approvals h
    WHERE h.status = 'pending' AND h.created_at > now() - interval '7 days'
      AND allgres_private.decision_rules_exist(allgres_private.decision_point_of_payload(h.payload))
      AND NOT EXISTS (SELECT 1 FROM allgres_private.decision_rule_checks c WHERE c.source_kind = 'approval' AND c.source_id = h.approval_id)
    UNION ALL
    SELECT 'proposal_decision', 'proposal', p.proposal_id
    FROM allgres_private.change_proposals p
    WHERE p.status = 'pending' AND p.created_at > now() - interval '7 days'
      AND allgres_private.decision_rules_exist('proposal_decision')
      AND NOT EXISTS (SELECT 1 FROM allgres_private.decision_rule_checks c WHERE c.source_kind = 'proposal' AND c.source_id = p.proposal_id)
    UNION ALL
    SELECT 'room_task_confirmation', 'room_proposal', rp.proposal_id
    FROM allgres_private.room_proposals rp
    WHERE rp.status = 'pending' AND rp.created_at > now() - interval '7 days'
      AND allgres_private.decision_rules_exist('room_task_confirmation')
      AND NOT EXISTS (SELECT 1 FROM allgres_private.decision_rule_checks c WHERE c.source_kind = 'room_proposal' AND c.source_id = rp.proposal_id)
    LIMIT 20
  LOOP
    v_n := v_n + 1;
    BEGIN
      v_res := allgres_private.decision_rules_apply_one(r.point, r.kind, r.id);
      IF v_res IN ('none', 'ask_model', 'error') AND r.kind IN ('approval', 'proposal') THEN
        IF r.kind = 'approval' THEN
          SELECT t.agent_id INTO v_agent FROM allgres_private.human_approvals h JOIN allgres_private.tasks t ON t.task_id = h.task_id WHERE h.approval_id = r.id;
        ELSE
          SELECT agent_id INTO v_agent FROM allgres_private.change_proposals WHERE proposal_id = r.id;
        END IF;
        PERFORM allgres_private.decision_delegate_item(r.point, r.kind, r.id, v_agent);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO allgres_private.decision_rule_checks (source_kind, source_id, point_key, result)
      VALUES (r.kind, r.id, r.point, 'error') ON CONFLICT DO NOTHING;
    END;
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- ---- Saving, ordering, trying -------------------------------------------

CREATE OR REPLACE FUNCTION allgres_public.fn_decision_rules(p_point_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object('ok', true, 'rules', COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'rule_id', r.rule_id, 'point_key', r.point_key, 'position', r.position, 'name', r.name, 'conditions', r.conditions,
      'outcome', r.outcome, 'answer', r.answer, 'is_enabled', r.is_enabled, 'created_at', r.created_at,
      'created_by', u.username,
      'applied', (SELECT count(*) FROM allgres_private.decision_rule_checks c WHERE c.rule_id = r.rule_id AND c.result = 'applied'))
      ORDER BY r.point_key, r.position, r.created_at)
    FROM allgres_private.decision_rules r LEFT JOIN allgres_private.users u ON u.user_id = r.created_by
    WHERE p_point_key IS NULL OR r.point_key = p_point_key), '[]'::jsonb))
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_decision_rule_save(
  p_token text, p_rule_id uuid, p_point_key text, p_name text, p_conditions jsonb,
  p_outcome text, p_answer text DEFAULT NULL, p_enabled boolean DEFAULT true, p_confirm_approve boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE := allgres_private.session_user(p_token);
  v_crit jsonb;
  v_id uuid := p_rule_id;
  v_enabled boolean := COALESCE(p_enabled, true);
BEGIN
  IF NOT allgres_private.decision_rule_point_ok(p_point_key) THEN
    RAISE EXCEPTION 'rules can be written for approvals, proposals, room tasks and the points of functions and procedures' USING ERRCODE = 'P0001';
  END IF;
  IF p_outcome NOT IN ('answer', 'ask_model', 'to_human') THEN
    RAISE EXCEPTION 'the outcome is answer, ask_model or to_human' USING ERRCODE = 'P0001';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' OR length(p_name) > 80 THEN
    RAISE EXCEPTION 'give the rule a name of up to 80 characters' USING ERRCODE = 'P0001';
  END IF;
  IF p_conditions IS NULL THEN p_conditions := '{}'::jsonb; END IF;
  PERFORM allgres_private.decision_cond_check(p_conditions, allgres_private.decision_rule_fields(p_point_key));
  IF p_outcome = 'answer' THEN
    SELECT criteria INTO v_crit FROM allgres_private.decision_points WHERE point_key = p_point_key ORDER BY version DESC LIMIT 1;
    IF p_answer IS NULL OR NOT (v_crit ? p_answer) THEN
      RAISE EXCEPTION 'the answer must be one of: %', (SELECT string_agg(k, ', ') FROM jsonb_object_keys(v_crit) k) USING ERRCODE = 'P0001';
    END IF;
    IF p_conditions = '{}'::jsonb THEN
      RAISE EXCEPTION 'a rule that decides needs a condition; without one it would decide everything' USING ERRCODE = 'P0001';
    END IF;
    IF p_point_key = 'room_task_confirmation' AND p_answer = 'confirm' THEN
      RAISE EXCEPTION 'a rule cannot confirm a room task: a person confirms it. A rule can decline it or send it to a person' USING ERRCODE = 'P0001';
    END IF;
    IF p_answer = 'approve' THEN
      IF NOT allgres_private.decision_cond_narrows(p_conditions, p_point_key) THEN
        RAISE EXCEPTION 'a rule that approves must say who or what it is about: an "all" with a condition on %',
          array_to_string(allgres_private.decision_rule_narrowing_fields(p_point_key), ', ') USING ERRCODE = 'P0001';
      END IF;
      IF v_enabled AND NOT COALESCE(p_confirm_approve, false) THEN
        RAISE EXCEPTION 'confirm that this rule approves without asking a person' USING ERRCODE = 'P0001';
      END IF;
    END IF;
  ELSE
    p_answer := NULL;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO allgres_private.decision_rules (point_key, position, name, conditions, outcome, answer, is_enabled, created_by)
    VALUES (p_point_key,
            COALESCE((SELECT max(position) FROM allgres_private.decision_rules WHERE point_key = p_point_key), 0) + 10,
            btrim(p_name), p_conditions, p_outcome, p_answer, v_enabled, u.user_id)
    RETURNING rule_id INTO v_id;
  ELSE
    UPDATE allgres_private.decision_rules
    SET name = btrim(p_name), conditions = p_conditions, outcome = p_outcome, answer = p_answer, is_enabled = v_enabled, updated_at = now()
    WHERE rule_id = v_id AND point_key = p_point_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'rule not found' USING ERRCODE = 'P0001'; END IF;
  END IF;
  PERFORM allgres_private.audit('decision_rules.save', jsonb_build_object(
    'rule_id', v_id, 'point_key', p_point_key, 'name', p_name, 'outcome', p_outcome, 'answer', p_answer,
    'enabled', v_enabled, 'conditions', p_conditions, 'by', u.username));
  RETURN jsonb_build_object('ok', true, 'rule_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_decision_rule_set_enabled(p_rule_id uuid, p_enabled boolean, p_confirm_approve boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE r allgres_private.decision_rules%ROWTYPE;
BEGIN
  SELECT * INTO r FROM allgres_private.decision_rules WHERE rule_id = p_rule_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'rule not found' USING ERRCODE = 'P0001'; END IF;
  IF p_enabled AND r.outcome = 'answer' AND r.answer = 'approve' AND NOT COALESCE(p_confirm_approve, false) THEN
    RAISE EXCEPTION 'confirm that this rule approves without asking a person' USING ERRCODE = 'P0001';
  END IF;
  UPDATE allgres_private.decision_rules SET is_enabled = p_enabled, updated_at = now() WHERE rule_id = p_rule_id;
  PERFORM allgres_private.audit('decision_rules.enabled', jsonb_build_object('rule_id', p_rule_id, 'name', r.name, 'enabled', p_enabled));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_decision_rule_delete(p_rule_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE r allgres_private.decision_rules%ROWTYPE;
BEGIN
  DELETE FROM allgres_private.decision_rules WHERE rule_id = p_rule_id RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'rule not found' USING ERRCODE = 'P0001'; END IF;
  PERFORM allgres_private.audit('decision_rules.delete', jsonb_build_object('rule_id', p_rule_id, 'name', r.name, 'point_key', r.point_key));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Swaps the rule with its neighbour in the order.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_rule_move(p_rule_id uuid, p_direction text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r allgres_private.decision_rules%ROWTYPE;
  n allgres_private.decision_rules%ROWTYPE;
BEGIN
  IF p_direction NOT IN ('up', 'down') THEN
    RAISE EXCEPTION 'direction is up or down' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM allgres_private.decision_rules WHERE rule_id = p_rule_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'rule not found' USING ERRCODE = 'P0001'; END IF;
  -- Number the point's rules 10, 20, 30 ... first, so equal positions cannot stick.
  WITH ranked AS (
    SELECT rule_id, row_number() OVER (ORDER BY position, created_at) * 10 AS p
    FROM allgres_private.decision_rules WHERE point_key = r.point_key)
  UPDATE allgres_private.decision_rules d SET position = ranked.p FROM ranked WHERE d.rule_id = ranked.rule_id;
  SELECT * INTO r FROM allgres_private.decision_rules WHERE rule_id = p_rule_id;
  SELECT * INTO n FROM allgres_private.decision_rules
  WHERE point_key = r.point_key AND CASE p_direction WHEN 'up' THEN position < r.position ELSE position > r.position END
  ORDER BY CASE p_direction WHEN 'up' THEN -position ELSE position END LIMIT 1;
  IF FOUND THEN
    UPDATE allgres_private.decision_rules SET position = n.position WHERE rule_id = r.rule_id;
    UPDATE allgres_private.decision_rules SET position = r.position WHERE rule_id = n.rule_id;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Tries a rule on the decisions people already made: how many it would have
-- matched, how often it gives the answer the person gave, and a few that
-- differ. Writes nothing.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_rule_backtest(p_point_key text, p_conditions jsonb, p_answer text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record; v_facts jsonb;
  v_checked int := 0; v_matched int := 0; v_agreed int := 0;
  v_diff jsonb := '[]'::jsonb;
BEGIN
  IF NOT allgres_private.decision_rule_point_ok(p_point_key) THEN
    RAISE EXCEPTION 'there are no rules for this point' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.decision_cond_check(COALESCE(p_conditions, '{}'::jsonb), allgres_private.decision_rule_fields(p_point_key));
  FOR r IN
    SELECT record_id, answer, source_kind, source_id, created_at FROM allgres_private.decision_records
    WHERE point_key = p_point_key AND decided_by = 'human' AND source_id IS NOT NULL
    ORDER BY created_at DESC LIMIT 500
  LOOP
    v_facts := allgres_private.decision_rule_facts(p_point_key, r.source_kind, r.source_id);
    IF v_facts IS NULL THEN CONTINUE; END IF;
    v_checked := v_checked + 1;
    IF allgres_private.decision_cond_eval(COALESCE(p_conditions, '{}'::jsonb), v_facts) THEN
      v_matched := v_matched + 1;
      IF p_answer IS NULL OR r.answer = p_answer THEN
        v_agreed := v_agreed + 1;
      ELSIF jsonb_array_length(v_diff) < 5 THEN
        v_diff := v_diff || jsonb_build_array(jsonb_build_object('person_said', r.answer, 'at', r.created_at,
          'agent', v_facts->>'agent', 'action', v_facts->>'action', 'resource', v_facts->>'resource', 'kind', v_facts->>'proposal_kind'));
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'checked', v_checked, 'matched', v_matched, 'agreed', v_agreed,
    'differed', v_matched - v_agreed, 'examples', v_diff);
END;
$fn$;

-- ---- Rules for room tasks -------------------------------------------------

-- A rule can only decline a room task or leave it to a person; a person
-- confirms (a task starts an agent). Same effects as a person declining:
-- the room is told, the proposal is closed, a decision record is kept.
CREATE OR REPLACE FUNCTION allgres_private.room_proposal_decline_by_rule(p_proposal_id uuid, p_rule_id uuid, p_rule_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  pr allgres_private.room_proposals%ROWTYPE;
  r allgres_private.rooms%ROWTYPE;
  v_assignee text; v_by text; v_role text; v_state text;
BEGIN
  SELECT * INTO pr FROM allgres_private.room_proposals WHERE proposal_id = p_proposal_id FOR UPDATE;
  IF NOT FOUND OR pr.status <> 'pending' THEN
    RAISE EXCEPTION 'this proposal has already been decided' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM allgres_private.rooms WHERE room_id = pr.room_id;
  IF r.status <> 'open' THEN
    RAISE EXCEPTION 'this room is closed' USING ERRCODE = 'P0001';
  END IF;
  SELECT name INTO v_assignee FROM allgres_private.agents WHERE agent_id = pr.assignee_agent_id;
  SELECT name INTO v_by FROM allgres_private.agents WHERE agent_id = pr.proposed_by_agent;
  SELECT ro.name INTO v_role FROM allgres_private.room_members m JOIN allgres_private.room_roles ro USING (role_id)
  WHERE m.room_id = pr.room_id AND m.agent_id = pr.assignee_agent_id;
  INSERT INTO allgres_private.room_messages (room_id, kind, content)
  VALUES (pr.room_id, 'notice', 'Declined by the rule "' || p_rule_name || '": the task for ' || v_assignee || ': ' || left(pr.goal, 300));
  UPDATE allgres_private.room_proposals SET status = 'declined', decided_at = now() WHERE proposal_id = p_proposal_id;
  v_state := 'Room: ' || r.name || E'\nPurpose: ' || r.purpose
    || E'\nProposed by: ' || COALESCE(v_by, 'the lead')
    || E'\nAssignee: ' || v_assignee || COALESCE(' (' || v_role || ')', '')
    || E'\nGoal: ' || left(pr.goal, 1000)
    || E'\nDiscussion: ' || (SELECT count(*) FROM allgres_private.room_messages WHERE room_id = pr.room_id AND kind = 'say')
    || ' messages from ' || (SELECT count(DISTINCT COALESCE(author_user_id::text, author_agent_id::text)) FROM allgres_private.room_messages
                              WHERE room_id = pr.room_id AND kind = 'say') || ' participants';
  BEGIN
    PERFORM allgres_private.record_decision('room_task_confirmation', v_state, 'decline', 'rule', NULL, NULL, 'room_proposal', p_proposal_id,
      jsonb_build_object('rule_id', p_rule_id));
  EXCEPTION WHEN others THEN
    PERFORM allgres_private.audit('decision_records.failed', jsonb_build_object(
      'source_kind', 'room_proposal', 'source_id', p_proposal_id, 'error', left(SQLERRM, 300)));
  END;
  PERFORM allgres_private.audit('rooms.proposal_decide', jsonb_build_object(
    'proposal_id', p_proposal_id, 'room_id', pr.room_id, 'accepted', false, 'rule_id', p_rule_id));
END;
$fn$;

-- ---- Decision points of functions and procedures -------------------------

-- Declares that a person is asked before this function (or procedure) runs, as
-- a decision point of its own: named, listed under Functions or Procedures,
-- with its own rules. The answers are approve and reject, as for any approval.
CREATE OR REPLACE FUNCTION allgres_public.fn_declare_decision_point(
  p_token text, p_kind text, p_ref_id uuid, p_title text, p_description text DEFAULT ''
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE := allgres_private.session_user(p_token);
  v_name text; v_key text; v_base allgres_private.decision_points%ROWTYPE;
BEGIN
  IF p_kind = 'function' THEN
    SELECT name INTO v_name FROM allgres_private.functions WHERE function_id = p_ref_id;
  ELSIF p_kind = 'procedure' THEN
    SELECT name INTO v_name FROM allgres_private.procedures WHERE procedure_id = p_ref_id;
  ELSE
    RAISE EXCEPTION 'kind is function or procedure' USING ERRCODE = 'P0001';
  END IF;
  IF v_name IS NULL THEN RAISE EXCEPTION '% not found', p_kind USING ERRCODE = 'P0001'; END IF;
  IF p_title IS NULL OR btrim(p_title) = '' OR length(p_title) > 100 THEN
    RAISE EXCEPTION 'give the decision point a name of up to 100 characters' USING ERRCODE = 'P0001';
  END IF;
  IF length(COALESCE(p_description, '')) > 400 THEN
    RAISE EXCEPTION 'the description is at most 400 characters' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM allgres_private.declared_decision_points WHERE ref_id = p_ref_id) THEN
    -- Declaring again renames it.
    SELECT point_key INTO v_key FROM allgres_private.declared_decision_points WHERE ref_id = p_ref_id;
    UPDATE allgres_private.decision_point_meta SET title = btrim(p_title), description = COALESCE(p_description, '') WHERE point_key = v_key;
    RETURN jsonb_build_object('ok', true, 'point_key', v_key, 'renamed', true);
  END IF;
  v_key := CASE p_kind WHEN 'function' THEN 'fn_' ELSE 'proc_' END || substr(replace(p_ref_id::text, '-', ''), 1, 16);
  SELECT * INTO v_base FROM allgres_private.decision_points WHERE point_key = 'approval_decision' ORDER BY version DESC LIMIT 1;
  INSERT INTO allgres_private.decision_points (point_key, version, instructions, criteria, state_fields, risk_level)
  VALUES (v_key, 1, 'Decide whether this agent may run the ' || p_kind || ' ' || v_name || ' now.',
    jsonb_build_object(
      'approve', 'The run is clear, within what the agent should be doing, and safe as described.',
      'reject',  'The run is unclear, outside what the agent should be doing, or unsafe as described.'),
    v_base.state_fields, 'medium')
  ON CONFLICT (point_key, version) DO NOTHING;
  INSERT INTO allgres_private.decision_point_meta (point_key, category, title, description)
  VALUES (v_key, CASE p_kind WHEN 'function' THEN 'Functions' ELSE 'Procedures' END, btrim(p_title), COALESCE(p_description, ''))
  ON CONFLICT (point_key) DO UPDATE SET title = EXCLUDED.title, description = EXCLUDED.description;
  INSERT INTO allgres_private.declared_decision_points (point_key, kind, ref_id, created_by) VALUES (v_key, p_kind, p_ref_id, u.user_id);
  PERFORM allgres_private.audit('decision_points.declare', jsonb_build_object(
    'point_key', v_key, 'kind', p_kind, 'ref_id', p_ref_id, 'name', v_name, 'by', u.username));
  RETURN jsonb_build_object('ok', true, 'point_key', v_key);
END;
$fn$;

-- Takes the declaration away. Its rules go with it (they would never be read);
-- what was decided stays in the decision records.
CREATE OR REPLACE FUNCTION allgres_public.fn_undeclare_decision_point(p_ref_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE v_key text;
BEGIN
  DELETE FROM allgres_private.declared_decision_points WHERE ref_id = p_ref_id RETURNING point_key INTO v_key;
  IF v_key IS NULL THEN RAISE EXCEPTION 'this has no decision point of its own' USING ERRCODE = 'P0001'; END IF;
  DELETE FROM allgres_private.decision_rules WHERE point_key = v_key;
  DELETE FROM allgres_private.decision_delegation WHERE point_key = v_key;
  DELETE FROM allgres_private.decision_point_meta WHERE point_key = v_key;
  PERFORM allgres_private.audit('decision_points.undeclare', jsonb_build_object('point_key', v_key, 'ref_id', p_ref_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_declared_decision_points()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object('ok', true, 'points', COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'point_key', d.point_key, 'kind', d.kind, 'ref_id', d.ref_id,
    'name', CASE d.kind WHEN 'function' THEN (SELECT name FROM allgres_private.functions WHERE function_id = d.ref_id)
                        ELSE (SELECT name FROM allgres_private.procedures WHERE procedure_id = d.ref_id) END,
    'title', m.title, 'description', m.description) ORDER BY m.title)
    FROM allgres_private.declared_decision_points d JOIN allgres_private.decision_point_meta m USING (point_key)), '[]'::jsonb))
$fn$;
