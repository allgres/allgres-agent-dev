-- Allgres control plane -- decision points and decision records.
--
-- A decision point is a place where a person picks one answer from a fixed
-- list: approve or reject an approval request, approve or reject a change
-- proposal. Every time a person decides one, this file keeps a record of the
-- situation, the question as it was asked, and the answer, in the shape
-- Laya's official trainer and evaluator read (docs/finetune.md in
-- NandhaKishorM/laya): a JSON line with `state`, `questions`, and
-- `expected`. Nothing here runs a model. PostgreSQL only keeps the records
-- and hands them back; training and evaluation happen outside it with
-- Laya's own tools. docs/decision-records.md explains it to an operator and
-- docs/stage1-design.md has the design.
--
-- The records are written whether or not Laya is connected, because a
-- person's own decision is the most valuable thing to learn from and it is
-- gone if it is not kept when it happens.
--
-- Loaded after sql/org_routing.sql (it reads the routing columns) and before
-- sql/selftest.sql (src/lib.rs). The final ownership and REVOKE pass in
-- sql/grants_and_facade.sql covers these objects like any other.

-- One row per version of a question. A change to the instructions, the
-- answer list, or the fields shown makes a new version and keeps the old one,
-- so a record always points at the question exactly as it was asked.
CREATE TABLE IF NOT EXISTS allgres_private.decision_points (
  point_key    text NOT NULL CHECK (point_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  version      int  NOT NULL CHECK (version >= 1),
  -- Only the choice question is supported so far.
  qtype        text NOT NULL DEFAULT 'choice' CHECK (qtype = 'choice'),
  instructions text NOT NULL CHECK (btrim(instructions) <> ''),
  -- {"<answer>": "<when to pick it>"}: Laya's `criteria`.
  criteria     jsonb NOT NULL CHECK (jsonb_typeof(criteria) = 'object' AND criteria <> '{}'::jsonb),
  -- Which facts about the situation go into `state`. A field that is not
  -- listed is never recorded, which is how a secret is kept out.
  state_fields text[] NOT NULL DEFAULT '{}',
  risk_level   text NOT NULL DEFAULT 'medium' CHECK (risk_level IN ('low', 'medium', 'high')),
  -- Reserved for the Laya stage; nothing reads it yet.
  mode         text NOT NULL DEFAULT 'off' CHECK (mode IN ('off', 'observe', 'delegate')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (point_key, version)
);

-- Append only: a record is never edited or deleted, so what was learned from
-- cannot quietly change. A later correction is a new label.
CREATE TABLE IF NOT EXISTS allgres_private.decision_records (
  record_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  point_key       text NOT NULL,
  point_version   int  NOT NULL,
  state           text NOT NULL,
  -- {"<point_key>": {"type", "instructions", "criteria"}} as it stood.
  questions       jsonb NOT NULL,
  decided_by      text NOT NULL CHECK (decided_by IN ('human', 'rule', 'llm', 'laya')),
  decider_user_id uuid,
  decided_via     text CHECK (decided_via IS NULL OR decided_via IN ('self', 'delegate', 'admin')),
  answer          text NOT NULL,
  source_kind     text,
  source_id       uuid,
  -- Fixed at insert from a hash of the point and the state, so two records of
  -- the same situation always land on the same side and the evaluation set
  -- never shares a situation with the training set.
  split           text NOT NULL CHECK (split IN ('train', 'eval')),
  context         jsonb NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (point_key, point_version) REFERENCES allgres_private.decision_points(point_key, version)
);
CREATE INDEX IF NOT EXISTS decision_records_point_idx ON allgres_private.decision_records (point_key, created_at);

-- The answer to learn from. A person's own decision gets a gold label when it
-- is recorded; a later correction adds another. Labels from a model (bronze)
-- and from outcomes (silver) have a place here for later stages.
CREATE TABLE IF NOT EXISTS allgres_private.decision_labels (
  label_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id          uuid NOT NULL REFERENCES allgres_private.decision_records(record_id),
  -- {"<point_key>": "<answer>"}: Laya's `expected`.
  expected           jsonb NOT NULL CHECK (jsonb_typeof(expected) = 'object'),
  tier               text NOT NULL CHECK (tier IN ('gold', 'silver', 'bronze')),
  source             text NOT NULL DEFAULT '',
  labeled_by_user_id uuid,
  -- clock_timestamp, not now(): two labels written in one transaction still
  -- order by when they were written.
  labeled_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  note               text NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS decision_labels_record_idx ON allgres_private.decision_labels (record_id);

CREATE TABLE IF NOT EXISTS allgres_private.decision_exports (
  export_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at           timestamptz NOT NULL DEFAULT now(),
  requested_by_user_id uuid,
  filter               jsonb NOT NULL,
  row_count            int NOT NULL,
  sha256               text NOT NULL
);

CREATE OR REPLACE FUNCTION allgres_private.forbid_decision_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  RAISE EXCEPTION 'decision records are append-only; add a label instead' USING ERRCODE = 'P0001';
END;
$fn$;

DROP TRIGGER IF EXISTS decision_records_append_only ON allgres_private.decision_records;
CREATE TRIGGER decision_records_append_only BEFORE UPDATE OR DELETE ON allgres_private.decision_records
  FOR EACH ROW EXECUTE FUNCTION allgres_private.forbid_decision_mutation();
DROP TRIGGER IF EXISTS decision_labels_append_only ON allgres_private.decision_labels;
CREATE TRIGGER decision_labels_append_only BEFORE UPDATE OR DELETE ON allgres_private.decision_labels
  FOR EACH ROW EXECUTE FUNCTION allgres_private.forbid_decision_mutation();

-- The two decision points that exist today. The wording is what a model is
-- shown, so it describes the situation and the choices plainly.
INSERT INTO allgres_private.decision_points (point_key, version, instructions, criteria, state_fields, risk_level)
VALUES
  ('approval_decision', 1,
   'Decide whether to approve this request from an agent to run or continue.',
   jsonb_build_object(
     'approve', 'The request is clear, within what the agent should be doing, and safe to run as described.',
     'reject',  'The request is unclear, outside what the agent should be doing, or unsafe as described.'),
   ARRAY['approval_type', 'reason', 'agent', 'goal', 'action', 'resource'], 'medium'),
  ('proposal_decision', 1,
   'Decide whether to approve this change that an agent proposed.',
   jsonb_build_object(
     'approve', 'The change is clearly described, matches its stated reason, and is safe to apply.',
     'reject',  'The change is unclear, does not match its stated reason, or is not safe to apply.'),
   ARRAY['proposal_kind', 'agent', 'target_agent', 'reason', 'change_summary'], 'medium')
ON CONFLICT (point_key, version) DO NOTHING;

-- The situation an approval request describes, as plain `Label: value` lines.
-- Only the fields the point lists are included, and only values that are safe
-- to keep: a URL loses its query string, and nothing that can carry a secret
-- (the request's own arguments or snapshot) is read at all.
CREATE OR REPLACE FUNCTION allgres_private.approval_decision_state(p_approval_id uuid, p_fields text[])
RETURNS text
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  h allgres_private.human_approvals%ROWTYPE;
  v_agent text; v_goal text; v_type text; v_res text;
  v_lines text[] := '{}';
BEGIN
  SELECT * INTO h FROM allgres_private.human_approvals WHERE approval_id = p_approval_id;
  IF NOT FOUND THEN
    RETURN '';
  END IF;
  SELECT a.name, s.goal INTO v_agent, v_goal
  FROM allgres_private.tasks t
  JOIN allgres_private.agents a ON a.agent_id = t.agent_id
  JOIN allgres_private.sessions s ON s.session_id = t.session_id
  WHERE t.task_id = h.task_id;
  v_type := CASE
    WHEN h.payload ? 'queue' THEN 'execution'
    WHEN h.payload ? 'ambiguous_outbound_call_id' THEN 'outbound_unknown'
    ELSE 'await_human' END;
  IF 'approval_type' = ANY(p_fields) THEN
    v_lines := v_lines || ('Approval type: ' || v_type);
  END IF;
  IF 'reason' = ANY(p_fields) AND jsonb_typeof(h.payload->'reason') = 'string' THEN
    v_lines := v_lines || ('Reason: ' || left(h.payload->>'reason', 600));
  END IF;
  IF 'agent' = ANY(p_fields) AND v_agent IS NOT NULL THEN
    v_lines := v_lines || ('Agent: ' || v_agent);
  END IF;
  IF 'goal' = ANY(p_fields) AND v_goal IS NOT NULL THEN
    v_lines := v_lines || ('Task goal: ' || left(v_goal, 600));
  END IF;
  IF 'action' = ANY(p_fields) AND jsonb_typeof(h.payload->'action') = 'string' THEN
    v_lines := v_lines || ('Action: ' || left(h.payload->>'action', 120));
  END IF;
  IF 'resource' = ANY(p_fields) AND jsonb_typeof(h.payload->'resource') = 'string' THEN
    v_res := regexp_replace(h.payload->>'resource', '[?#].*$', '');
    v_lines := v_lines || ('Resource: ' || left(v_res, 200));
  END IF;
  RETURN array_to_string(v_lines, E'\n');
END;
$fn$;

-- The same for a change proposal. The change itself is summarised by what it
-- touches, never by its body or prompt text.
CREATE OR REPLACE FUNCTION allgres_private.proposal_decision_state(p_proposal_id uuid, p_fields text[])
RETURNS text
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  cp allgres_private.change_proposals%ROWTYPE;
  v_agent text; v_target text; v_summary text;
  v_lines text[] := '{}';
BEGIN
  SELECT * INTO cp FROM allgres_private.change_proposals WHERE proposal_id = p_proposal_id;
  IF NOT FOUND THEN
    RETURN '';
  END IF;
  SELECT name INTO v_agent FROM allgres_private.agents WHERE agent_id = cp.agent_id;
  SELECT name INTO v_target FROM allgres_private.agents WHERE agent_id = cp.target_agent_id;
  v_summary := CASE cp.kind
    WHEN 'create_function' THEN format('function %s: %s', cp.proposed_changes->>'name', left(cp.proposed_changes->>'description', 300))
    WHEN 'create_procedure' THEN format('usage document %s: %s', cp.proposed_changes->>'name', left(cp.proposed_changes->>'content', 300))
    WHEN 'update_function' THEN format('update to a function: %s', left(cp.proposed_changes->>'description', 300))
    WHEN 'create_agent' THEN format('new agent %s', cp.proposed_changes->>'name')
    WHEN 'function_override' THEN format('model override, step %s, candidate %s/%s', cp.proposed_changes->>'op',
                                         cp.proposed_changes->>'candidate_provider', cp.proposed_changes->>'candidate_model')
    ELSE format('changes %s', (SELECT string_agg(k, ', ' ORDER BY k) FROM jsonb_object_keys(
                  CASE WHEN jsonb_typeof(cp.proposed_changes) = 'object' THEN cp.proposed_changes ELSE '{}'::jsonb END) k))
  END;
  IF 'proposal_kind' = ANY(p_fields) THEN
    v_lines := v_lines || ('Proposal kind: ' || cp.kind);
  END IF;
  IF 'agent' = ANY(p_fields) AND v_agent IS NOT NULL THEN
    v_lines := v_lines || ('Proposed by: ' || v_agent);
  END IF;
  IF 'target_agent' = ANY(p_fields) AND v_target IS NOT NULL THEN
    v_lines := v_lines || ('Target agent: ' || v_target);
  END IF;
  IF 'reason' = ANY(p_fields) AND cp.reason IS NOT NULL THEN
    v_lines := v_lines || ('Reason: ' || left(cp.reason, 600));
  END IF;
  IF 'change_summary' = ANY(p_fields) AND v_summary IS NOT NULL THEN
    v_lines := v_lines || ('Change: ' || left(v_summary, 400));
  END IF;
  RETURN array_to_string(v_lines, E'\n');
END;
$fn$;

-- Keeps one decision. Returns the record id, or NULL when the point does not
-- exist. The answer must be one the question offers. A person's decision also
-- gets its gold label here, in the same statement, so a record and the answer
-- to learn from can never be apart.
CREATE OR REPLACE FUNCTION allgres_private.record_decision(
  p_point_key text, p_state text, p_answer text,
  p_decided_by text DEFAULT 'human', p_user_id uuid DEFAULT NULL, p_via text DEFAULT NULL,
  p_source_kind text DEFAULT NULL, p_source_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
AS $fn$
DECLARE
  pt allgres_private.decision_points%ROWTYPE;
  v_state text := COALESCE(p_state, '');
  v_context jsonb := COALESCE(p_context, '{}'::jsonb);
  v_split text;
  v_id uuid;
BEGIN
  SELECT * INTO pt FROM allgres_private.decision_points WHERE point_key = p_point_key ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF NOT (pt.criteria ? p_answer) THEN
    RAISE EXCEPTION 'answer "%" is not one of the answers for %', p_answer, p_point_key USING ERRCODE = 'P0001';
  END IF;
  IF length(v_state) > 4000 THEN
    v_state := left(v_state, 4000);
    v_context := v_context || jsonb_build_object('state_truncated', true);
  END IF;
  -- 10% of situations go to evaluation. The mask keeps the hash non-negative.
  v_split := CASE WHEN ((hashtextextended(pt.point_key || E'\n' || v_state, 0) & 9223372036854775807) % 100) < 10
                  THEN 'eval' ELSE 'train' END;
  INSERT INTO allgres_private.decision_records (
    point_key, point_version, state, questions, decided_by, decider_user_id, decided_via,
    answer, source_kind, source_id, split, context)
  VALUES (
    pt.point_key, pt.version, v_state,
    jsonb_build_object(pt.point_key, jsonb_build_object(
      'type', pt.qtype, 'instructions', pt.instructions, 'criteria', pt.criteria)),
    p_decided_by, p_user_id, p_via, p_answer, p_source_kind, p_source_id, v_split, v_context)
  RETURNING record_id INTO v_id;
  IF p_decided_by = 'human' THEN
    INSERT INTO allgres_private.decision_labels (record_id, expected, tier, source, labeled_by_user_id)
    VALUES (v_id, jsonb_build_object(pt.point_key, p_answer), 'gold', 'human_decision', p_user_id);
  END IF;
  RETURN v_id;
END;
$fn$;

-- fn_decide_approval and fn_decide_proposal flag their own status change, so a
-- status that something else sets (an expiry, a system rejection, a stale
-- proposal) is never mistaken for a person's decision. The flag is cleared
-- the moment it is used.
CREATE OR REPLACE FUNCTION allgres_private.record_approval_decision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF OLD.status = 'pending' AND NEW.status IN ('approved', 'rejected')
     AND current_setting('allgres.human_decision', true) = 'approval' THEN
    PERFORM set_config('allgres.human_decision', '', true);
    BEGIN
      PERFORM record_decision(
        'approval_decision',
        approval_decision_state(NEW.approval_id, (SELECT state_fields FROM decision_points
                                                  WHERE point_key = 'approval_decision' ORDER BY version DESC LIMIT 1)),
        CASE NEW.status WHEN 'approved' THEN 'approve' ELSE 'reject' END,
        'human', NEW.decided_by_user_id, NEW.decided_via, 'approval', NEW.approval_id,
        jsonb_build_object('task_id', NEW.task_id));
    EXCEPTION WHEN OTHERS THEN
      -- A decision must never fail because its record could not be kept.
      PERFORM audit('decision_records.failed', jsonb_build_object(
        'source_kind', 'approval', 'source_id', NEW.approval_id, 'error', SQLERRM));
    END;
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.record_proposal_decision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF OLD.status = 'pending' AND NEW.status IN ('approved', 'rejected')
     AND current_setting('allgres.human_decision', true) = 'proposal' THEN
    PERFORM set_config('allgres.human_decision', '', true);
    BEGIN
      PERFORM record_decision(
        'proposal_decision',
        proposal_decision_state(NEW.proposal_id, (SELECT state_fields FROM decision_points
                                                  WHERE point_key = 'proposal_decision' ORDER BY version DESC LIMIT 1)),
        CASE NEW.status WHEN 'approved' THEN 'approve' ELSE 'reject' END,
        'human', NEW.decided_by_user_id, NEW.decided_via, 'proposal', NEW.proposal_id,
        jsonb_build_object('kind', NEW.kind));
    EXCEPTION WHEN OTHERS THEN
      PERFORM audit('decision_records.failed', jsonb_build_object(
        'source_kind', 'proposal', 'source_id', NEW.proposal_id, 'error', SQLERRM));
    END;
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS record_approval_decision_trg ON allgres_private.human_approvals;
CREATE TRIGGER record_approval_decision_trg AFTER UPDATE OF status ON allgres_private.human_approvals
  FOR EACH ROW EXECUTE FUNCTION allgres_private.record_approval_decision();
DROP TRIGGER IF EXISTS record_proposal_decision_trg ON allgres_private.change_proposals;
CREATE TRIGGER record_proposal_decision_trg AFTER UPDATE OF status ON allgres_private.change_proposals
  FOR EACH ROW EXECUTE FUNCTION allgres_private.record_proposal_decision();

-- ---------------------------------------------------------------------------
-- Operator API. Every function audits; dashboard_rpc gates them to admins.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_public.fn_decision_points()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object('ok', true, 'points', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'point_key', p.point_key, 'version', p.version, 'qtype', p.qtype, 'instructions', p.instructions,
      'criteria', p.criteria, 'state_fields', to_jsonb(p.state_fields), 'risk_level', p.risk_level, 'mode', p.mode)
      ORDER BY p.point_key)
    FROM allgres_private.decision_points p
    WHERE p.version = (SELECT max(version) FROM allgres_private.decision_points WHERE point_key = p.point_key)
  ), '[]'::jsonb))
$fn$;

-- Registers a point, or changes one: a change to the instructions, answers,
-- or fields makes a new version and leaves the old one for the records that
-- already point at it.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_point_save(
  p_point_key text, p_instructions text, p_criteria jsonb, p_state_fields text[] DEFAULT '{}',
  p_risk_level text DEFAULT 'medium'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  cur allgres_private.decision_points%ROWTYPE;
  v_version int;
  v_fields text[] := COALESCE(p_state_fields, '{}');
BEGIN
  IF p_point_key IS NULL OR p_point_key !~ '^[a-z][a-z0-9_]{0,62}$' THEN
    RAISE EXCEPTION 'point_key must be lowercase letters, digits, and underscores' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO cur FROM allgres_private.decision_points WHERE point_key = p_point_key ORDER BY version DESC LIMIT 1;
  IF FOUND AND cur.instructions = btrim(COALESCE(p_instructions, '')) AND cur.criteria = p_criteria
     AND cur.state_fields = v_fields AND cur.risk_level = COALESCE(p_risk_level, 'medium') THEN
    RETURN jsonb_build_object('ok', true, 'point_key', p_point_key, 'version', cur.version, 'changed', false);
  END IF;
  v_version := COALESCE(cur.version, 0) + 1;
  INSERT INTO allgres_private.decision_points (point_key, version, instructions, criteria, state_fields, risk_level, mode)
  VALUES (p_point_key, v_version, btrim(COALESCE(p_instructions, '')), p_criteria, v_fields,
          COALESCE(p_risk_level, 'medium'), COALESCE(cur.mode, 'off'));
  PERFORM allgres_private.audit('decisions.points.save', jsonb_build_object('point_key', p_point_key, 'version', v_version));
  RETURN jsonb_build_object('ok', true, 'point_key', p_point_key, 'version', v_version, 'changed', true);
END;
$fn$;

-- What has been kept, per point: how many records, how many are a person's
-- own, how they split, and how many carry each kind of label.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_stats()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object('ok', true, 'points', COALESCE((
    SELECT jsonb_agg(x ORDER BY x->>'point_key') FROM (
      SELECT jsonb_build_object(
        'point_key', r.point_key,
        'records', count(*),
        'human', count(*) FILTER (WHERE r.decided_by = 'human'),
        'train', count(*) FILTER (WHERE r.split = 'train'),
        'eval', count(*) FILTER (WHERE r.split = 'eval'),
        'gold', count(*) FILTER (WHERE b.tier = 'gold'),
        'silver', count(*) FILTER (WHERE b.tier = 'silver'),
        'bronze', count(*) FILTER (WHERE b.tier = 'bronze'),
        'first_at', min(r.created_at), 'last_at', max(r.created_at)) AS x
      FROM allgres_private.decision_records r
      LEFT JOIN LATERAL (
        SELECT l.tier FROM allgres_private.decision_labels l WHERE l.record_id = r.record_id
        ORDER BY CASE l.tier WHEN 'gold' THEN 1 WHEN 'silver' THEN 2 ELSE 3 END, l.labeled_at DESC LIMIT 1
      ) b ON true
      GROUP BY r.point_key
    ) s), '[]'::jsonb))
$fn$;

-- Corrects or adds an answer for a record already kept. The record itself is
-- never changed; the new label is what an export picks up.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_add_label(
  p_record_id uuid, p_answer text, p_tier text DEFAULT 'gold', p_note text DEFAULT '', p_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  r allgres_private.decision_records%ROWTYPE;
  v_id uuid;
BEGIN
  IF p_tier IS NULL OR p_tier NOT IN ('gold', 'silver', 'bronze') THEN
    RAISE EXCEPTION 'tier must be gold, silver, or bronze' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM allgres_private.decision_records WHERE record_id = p_record_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record not found' USING ERRCODE = 'P0001';
  END IF;
  IF NOT (r.questions->r.point_key->'criteria' ? p_answer) THEN
    RAISE EXCEPTION 'answer "%" is not one of the answers for %', p_answer, r.point_key USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.decision_labels (record_id, expected, tier, source, labeled_by_user_id, note)
  VALUES (p_record_id, jsonb_build_object(r.point_key, p_answer), p_tier, 'correction', p_user_id, COALESCE(p_note, ''))
  RETURNING label_id INTO v_id;
  PERFORM allgres_private.audit('decisions.label.add', jsonb_build_object(
    'record_id', p_record_id, 'label_id', v_id, 'tier', p_tier));
  RETURN jsonb_build_object('ok', true, 'label_id', v_id);
END;
$fn$;

-- The export: one line of Laya's JSONL per record, for `laya-train` (split
-- 'train') or `laya-evals` (split 'eval'). A record with several labels is
-- exported once, with the highest tier among those asked for and, within a
-- tier, the latest label. Every call is logged with its filter, row count,
-- and the SHA-256 of what was returned.
CREATE OR REPLACE FUNCTION allgres_public.fn_decision_export(
  p_split text DEFAULT 'train', p_point_key text DEFAULT NULL,
  p_tiers text[] DEFAULT ARRAY['gold', 'silver'], p_since timestamptz DEFAULT NULL,
  p_until timestamptz DEFAULT NULL, p_limit int DEFAULT 10000, p_offset int DEFAULT 0,
  p_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 10000), 1), 50000);
  v_offset int := GREATEST(COALESCE(p_offset, 0), 0);
  v_tiers text[] := COALESCE(p_tiers, ARRAY['gold', 'silver']);
  v_text text;
  v_count int;
  v_hash text;
BEGIN
  IF p_split IS NULL OR p_split NOT IN ('train', 'eval', 'all') THEN
    RAISE EXCEPTION 'split must be train, eval, or all' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_tiers <@ ARRAY['gold', 'silver', 'bronze'] THEN
    RAISE EXCEPTION 'tiers must be gold, silver, or bronze' USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*), COALESCE(string_agg(line, E'\n' ORDER BY ord) || E'\n', '')
  INTO v_count, v_text
  FROM (
    SELECT row_number() OVER (ORDER BY r.created_at, r.record_id) AS ord,
           json_build_object('state', r.state, 'questions', r.questions::json, 'expected', b.expected::json)::text AS line
    FROM allgres_private.decision_records r
    JOIN LATERAL (
      SELECT l.expected FROM allgres_private.decision_labels l
      WHERE l.record_id = r.record_id AND l.tier = ANY(v_tiers)
      ORDER BY CASE l.tier WHEN 'gold' THEN 1 WHEN 'silver' THEN 2 ELSE 3 END, l.labeled_at DESC, l.label_id DESC
      LIMIT 1
    ) b ON true
    WHERE (p_split = 'all' OR r.split = p_split)
      AND (p_point_key IS NULL OR r.point_key = p_point_key)
      AND (p_since IS NULL OR r.created_at >= p_since)
      AND (p_until IS NULL OR r.created_at < p_until)
    ORDER BY r.created_at, r.record_id
    OFFSET v_offset LIMIT v_limit
  ) q;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  INSERT INTO allgres_private.decision_exports (requested_by_user_id, filter, row_count, sha256)
  VALUES (p_user_id, jsonb_build_object('split', p_split, 'point_key', p_point_key, 'tiers', to_jsonb(v_tiers),
          'since', p_since, 'until', p_until, 'limit', v_limit, 'offset', v_offset), v_count, v_hash);
  PERFORM allgres_private.audit('decisions.export', jsonb_build_object(
    'split', p_split, 'point_key', p_point_key, 'rows', v_count, 'sha256', v_hash));
  RETURN jsonb_build_object('ok', true, 'count', v_count, 'sha256', v_hash, 'jsonl', v_text);
END;
$fn$;
