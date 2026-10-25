-- Allgres control plane -- people, roles, and approval routing.
--
-- Until now an approval request or change proposal could be decided by any
-- admin, or by a user who had been assigned the requesting agent. Nothing
-- said who *should* decide. This file adds that: org units and roles for
-- people, rules that route a request to a role, an optional escalation to
-- a second role after a deadline, and time-boxed delegation between people.
-- docs/approvals-and-roles.md explains it to an operator;
-- docs/stage1-design.md has the design.
--
-- Loaded after sql/canvas.sql (a rule can match a Canvas group) and before
-- sql/selftest.sql (src/lib.rs). The final ownership and REVOKE pass in
-- sql/grants_and_facade.sql covers these objects like any other.
--
-- Two promises this file keeps:
--
-- * With no rule, nothing changes. A request that no rule matched is decided
--   exactly as before (admins, plus a user assigned to the agent).
-- * A role grants no other power. Roles here only answer "who may decide
--   this request"; they never widen what a user can read or run.

CREATE TABLE IF NOT EXISTS allgres_private.org_units (
  unit_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
  -- Units nest (a division holding teams). fn_org_save_unit refuses a
  -- parent that is the unit itself or one of its own descendants.
  parent_unit_id uuid REFERENCES allgres_private.org_units(unit_id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS allgres_private.org_roles (
  role_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
  description text NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- One row is one fact: this person holds this role, in this unit (or, with a
-- NULL unit, anywhere). The same person may have many rows. The unit column
-- sits in a unique index through COALESCE because NULLs never collide in a
-- plain primary key.
CREATE TABLE IF NOT EXISTS allgres_private.org_memberships (
  membership_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  unit_id       uuid REFERENCES allgres_private.org_units(unit_id) ON DELETE CASCADE,
  role_id       uuid NOT NULL REFERENCES allgres_private.org_roles(role_id) ON DELETE CASCADE,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS org_memberships_unique_idx
  ON allgres_private.org_memberships (user_id, role_id, COALESCE(unit_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX IF NOT EXISTS org_memberships_role_idx ON allgres_private.org_memberships (role_id);

-- Which role decides which request. A rule is deleted, not weakened, when the
-- role or unit it names is deleted (ON DELETE CASCADE), so a deleted
-- restriction can never widen into "anyone".
CREATE TABLE IF NOT EXISTS allgres_private.approval_rules (
  rule_id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  text NOT NULL DEFAULT '',
  priority              int  NOT NULL DEFAULT 100,
  applies_to            text NOT NULL CHECK (applies_to IN ('approval', 'proposal')),
  -- Match only requests from agents in this Canvas group or one below it.
  match_agent_group_id  uuid REFERENCES allgres_private.agent_groups(group_id) ON DELETE CASCADE,
  -- approval: await_human | execution | outbound_unknown.
  -- proposal: the change_proposals.kind (create_function, policy_change, ...).
  match_kind            text,
  decider_role_id       uuid NOT NULL REFERENCES allgres_private.org_roles(role_id) ON DELETE CASCADE,
  -- When set, only a holder of the role *in this unit* may decide.
  decider_unit_id       uuid REFERENCES allgres_private.org_units(unit_id) ON DELETE CASCADE,
  -- After this long without a decision, holders of escalate_role may decide
  -- too. Both must be set for escalation to apply.
  escalate_after        interval CHECK (escalate_after IS NULL OR escalate_after > interval '0'),
  escalate_role_id      uuid REFERENCES allgres_private.org_roles(role_id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now()
);

-- "I am away; let her decide in my place", for a bounded time.
CREATE TABLE IF NOT EXISTS allgres_private.approval_delegations (
  delegation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_user_id  uuid NOT NULL REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  to_user_id    uuid NOT NULL REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  valid_from    timestamptz NOT NULL DEFAULT now(),
  valid_until   timestamptz NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (from_user_id <> to_user_id),
  CHECK (valid_until > valid_from)
);
CREATE INDEX IF NOT EXISTS approval_delegations_to_idx ON allgres_private.approval_delegations (to_user_id);

-- The routing, copied onto the request when it is created. Deliberately not
-- foreign keys: changing or deleting a rule later must not rewrite a request
-- that is already waiting. A dangling role simply matches nobody, so only
-- admins can then decide it.
ALTER TABLE allgres_private.human_approvals
  ADD COLUMN IF NOT EXISTS routed_rule_id uuid,
  ADD COLUMN IF NOT EXISTS routed_role_id uuid,
  ADD COLUMN IF NOT EXISTS routed_unit_id uuid,
  ADD COLUMN IF NOT EXISTS escalate_at timestamptz,
  ADD COLUMN IF NOT EXISTS escalate_role_id uuid,
  ADD COLUMN IF NOT EXISTS decided_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS decided_via text CHECK (decided_via IS NULL OR decided_via IN ('self', 'delegate', 'admin'));
ALTER TABLE allgres_private.change_proposals
  ADD COLUMN IF NOT EXISTS routed_rule_id uuid,
  ADD COLUMN IF NOT EXISTS routed_role_id uuid,
  ADD COLUMN IF NOT EXISTS routed_unit_id uuid,
  ADD COLUMN IF NOT EXISTS escalate_at timestamptz,
  ADD COLUMN IF NOT EXISTS escalate_role_id uuid,
  ADD COLUMN IF NOT EXISTS decided_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS decided_via text CHECK (decided_via IS NULL OR decided_via IN ('self', 'delegate', 'admin'));

-- The Canvas group an agent sits in, plus every group above that one.
CREATE OR REPLACE FUNCTION allgres_private.agent_group_chain(p_agent_id uuid)
RETURNS SETOF uuid
LANGUAGE sql
STABLE
AS $fn$
  WITH RECURSIVE up(group_id) AS (
    SELECT m.group_id FROM allgres_private.agent_group_members m WHERE m.agent_id = p_agent_id
    UNION
    SELECT g.parent_group_id
    FROM up
    JOIN allgres_private.agent_groups g ON g.group_id = up.group_id
    WHERE g.parent_group_id IS NOT NULL
  )
  SELECT group_id FROM up
$fn$;

-- The first rule that fits, or a row with every column NULL when none does:
-- lowest priority number first, then a rule that names a group before one
-- that does not, then one that names a kind, then the oldest.
CREATE OR REPLACE FUNCTION allgres_private.pick_approval_rule(p_applies text, p_agent_id uuid, p_kind text)
RETURNS allgres_private.approval_rules
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  r allgres_private.approval_rules%ROWTYPE;
BEGIN
  SELECT * INTO r
  FROM allgres_private.approval_rules x
  WHERE x.applies_to = p_applies
    AND (x.match_kind IS NULL OR x.match_kind = p_kind)
    AND (x.match_agent_group_id IS NULL
         OR x.match_agent_group_id IN (SELECT allgres_private.agent_group_chain(p_agent_id)))
  ORDER BY x.priority, (x.match_agent_group_id IS NOT NULL) DESC, (x.match_kind IS NOT NULL) DESC, x.created_at
  LIMIT 1;
  RETURN r;
END;
$fn$;

-- Stamps the matching rule's routing onto a new approval request. Runs on
-- every insert, so the four places that create one (an agent's await_human,
-- an execution rule that needs approval, an outbound call whose result is
-- unknown) need no change.
CREATE OR REPLACE FUNCTION allgres_private.route_new_approval()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_agent uuid;
  v_kind text;
  r allgres_private.approval_rules%ROWTYPE;
BEGIN
  IF NEW.routed_role_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  SELECT t.agent_id INTO v_agent FROM allgres_private.tasks t WHERE t.task_id = NEW.task_id;
  v_kind := CASE
    WHEN NEW.payload ? 'queue' THEN 'execution'
    WHEN NEW.payload ? 'ambiguous_outbound_call_id' THEN 'outbound_unknown'
    ELSE 'await_human' END;
  r := allgres_private.pick_approval_rule('approval', v_agent, v_kind);
  IF r.rule_id IS NOT NULL THEN
    NEW.routed_rule_id := r.rule_id;
    NEW.routed_role_id := r.decider_role_id;
    NEW.routed_unit_id := r.decider_unit_id;
    IF r.escalate_after IS NOT NULL AND r.escalate_role_id IS NOT NULL THEN
      NEW.escalate_at := clock_timestamp() + r.escalate_after;
      NEW.escalate_role_id := r.escalate_role_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.route_new_proposal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  r allgres_private.approval_rules%ROWTYPE;
BEGIN
  IF NEW.routed_role_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  r := allgres_private.pick_approval_rule('proposal', COALESCE(NEW.target_agent_id, NEW.agent_id), NEW.kind);
  IF r.rule_id IS NOT NULL THEN
    NEW.routed_rule_id := r.rule_id;
    NEW.routed_role_id := r.decider_role_id;
    NEW.routed_unit_id := r.decider_unit_id;
    IF r.escalate_after IS NOT NULL AND r.escalate_role_id IS NOT NULL THEN
      NEW.escalate_at := clock_timestamp() + r.escalate_after;
      NEW.escalate_role_id := r.escalate_role_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS route_new_approval_trg ON allgres_private.human_approvals;
CREATE TRIGGER route_new_approval_trg BEFORE INSERT ON allgres_private.human_approvals
  FOR EACH ROW EXECUTE FUNCTION allgres_private.route_new_approval();
DROP TRIGGER IF EXISTS route_new_proposal_trg ON allgres_private.change_proposals;
CREATE TRIGGER route_new_proposal_trg BEFORE INSERT ON allgres_private.change_proposals
  FOR EACH ROW EXECUTE FUNCTION allgres_private.route_new_proposal();

-- What may this user do with this request?
--   'admin'    an administrator (always may decide)
--   'self'     decides on their own authority
--   'delegate' decides in place of someone who delegated to them
--   'viewer'   may see it, may not decide it
--   NULL       may neither see nor decide it
--
-- A request that no rule routed keeps the original rule: an assigned user
-- decides an approval for their agent, and a policy_change proposal for an
-- agent they are assigned to. A routed request is decided only by the routed
-- role (in the routed unit, when one is named), by the escalation role once
-- escalate_at has passed, or by someone those people delegated to. Its
-- agent's assigned user keeps read access but not the decision, so a routing
-- rule cannot be sidestepped by the person it routes around.
CREATE OR REPLACE FUNCTION allgres_private.decision_access(p_user_id uuid, p_kind text, p_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_role uuid; v_unit uuid; v_esc_at timestamptz; v_esc_role uuid;
  v_agent uuid; v_pkind text;
  v_assigned boolean;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO u FROM allgres_private.users WHERE user_id = p_user_id AND is_active;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF u.role = 'admin' THEN
    RETURN 'admin';
  END IF;

  IF p_kind = 'approval' THEN
    SELECT h.routed_role_id, h.routed_unit_id, h.escalate_at, h.escalate_role_id, t.agent_id, NULL
    INTO v_role, v_unit, v_esc_at, v_esc_role, v_agent, v_pkind
    FROM allgres_private.human_approvals h
    LEFT JOIN allgres_private.tasks t ON t.task_id = h.task_id
    WHERE h.approval_id = p_id;
  ELSIF p_kind = 'proposal' THEN
    SELECT cp.routed_role_id, cp.routed_unit_id, cp.escalate_at, cp.escalate_role_id,
           COALESCE(cp.target_agent_id, cp.agent_id), cp.kind
    INTO v_role, v_unit, v_esc_at, v_esc_role, v_agent, v_pkind
    FROM allgres_private.change_proposals cp
    WHERE cp.proposal_id = p_id;
  ELSE
    RETURN NULL;
  END IF;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_assigned := v_agent IS NOT NULL AND EXISTS (
    SELECT 1 FROM allgres_private.user_agent_assignments ua
    WHERE ua.user_id = p_user_id AND ua.agent_id = v_agent);

  IF v_role IS NULL THEN
    -- Not routed: the original rule. Only a policy_change proposal was ever
    -- visible to a non-admin; the other kinds stay admin-only.
    IF p_kind = 'proposal' AND v_pkind <> 'policy_change' THEN
      RETURN NULL;
    END IF;
    RETURN CASE WHEN v_assigned THEN 'self' END;
  END IF;

  IF EXISTS (
    SELECT 1 FROM allgres_private.org_memberships m
    WHERE m.user_id = p_user_id
      AND ((m.role_id = v_role AND (v_unit IS NULL OR m.unit_id = v_unit))
           OR (v_esc_at IS NOT NULL AND v_esc_at <= clock_timestamp() AND m.role_id = v_esc_role))
  ) THEN
    RETURN 'self';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM allgres_private.approval_delegations d
    JOIN allgres_private.org_memberships m ON m.user_id = d.from_user_id
    WHERE d.to_user_id = p_user_id
      AND clock_timestamp() >= d.valid_from AND clock_timestamp() < d.valid_until
      AND ((m.role_id = v_role AND (v_unit IS NULL OR m.unit_id = v_unit))
           OR (v_esc_at IS NOT NULL AND v_esc_at <= clock_timestamp() AND m.role_id = v_esc_role))
  ) THEN
    RETURN 'delegate';
  END IF;
  IF v_assigned AND (p_kind = 'approval' OR v_pkind = 'policy_change') THEN
    RETURN 'viewer';
  END IF;
  RETURN NULL;
END;
$fn$;

-- Records who decided, after fn_decide_approval / fn_decide_proposal
-- succeeded. A decision made from psql (no session) leaves both NULL.
CREATE OR REPLACE FUNCTION allgres_private.stamp_decider(p_kind text, p_id uuid, p_user_id uuid, p_via text)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;
  IF p_kind = 'approval' THEN
    UPDATE allgres_private.human_approvals SET decided_by_user_id = p_user_id, decided_via = p_via
    WHERE approval_id = p_id;
  ELSE
    UPDATE allgres_private.change_proposals SET decided_by_user_id = p_user_id, decided_via = p_via
    WHERE proposal_id = p_id;
  END IF;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Operator API. Every function audits, so psql gets the same trail as the
-- dashboard; dashboard_rpc gates them all to admins.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_public.fn_org_state()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'ok', true,
    'units', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'unit_id', u.unit_id, 'name', u.name, 'parent_unit_id', u.parent_unit_id) ORDER BY u.name)
      FROM allgres_private.org_units u), '[]'::jsonb),
    'roles', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'role_id', r.role_id, 'name', r.name, 'description', r.description) ORDER BY r.name)
      FROM allgres_private.org_roles r), '[]'::jsonb),
    'memberships', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'membership_id', m.membership_id, 'user_id', m.user_id, 'username', us.username,
        'unit_id', m.unit_id, 'unit', un.name, 'role_id', m.role_id, 'role', ro.name)
        ORDER BY us.username, ro.name)
      FROM allgres_private.org_memberships m
      JOIN allgres_private.users us ON us.user_id = m.user_id
      JOIN allgres_private.org_roles ro ON ro.role_id = m.role_id
      LEFT JOIN allgres_private.org_units un ON un.unit_id = m.unit_id), '[]'::jsonb),
    'rules', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'rule_id', x.rule_id, 'name', x.name, 'priority', x.priority, 'applies_to', x.applies_to,
        'match_agent_group_id', x.match_agent_group_id, 'match_group', g.name, 'match_kind', x.match_kind,
        'decider_role_id', x.decider_role_id, 'decider_role', dr.name,
        'decider_unit_id', x.decider_unit_id, 'decider_unit', du.name,
        'escalate_after_seconds', extract(epoch FROM x.escalate_after)::bigint,
        'escalate_role_id', x.escalate_role_id, 'escalate_role', er.name)
        ORDER BY x.priority, x.created_at)
      FROM allgres_private.approval_rules x
      JOIN allgres_private.org_roles dr ON dr.role_id = x.decider_role_id
      LEFT JOIN allgres_private.org_units du ON du.unit_id = x.decider_unit_id
      LEFT JOIN allgres_private.org_roles er ON er.role_id = x.escalate_role_id
      LEFT JOIN allgres_private.agent_groups g ON g.group_id = x.match_agent_group_id), '[]'::jsonb),
    'delegations', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'delegation_id', d.delegation_id, 'from_user_id', d.from_user_id, 'from', fu.username,
        'to_user_id', d.to_user_id, 'to', tu.username,
        'valid_from', d.valid_from, 'valid_until', d.valid_until,
        'active', clock_timestamp() >= d.valid_from AND clock_timestamp() < d.valid_until)
        ORDER BY d.valid_until DESC)
      FROM allgres_private.approval_delegations d
      JOIN allgres_private.users fu ON fu.user_id = d.from_user_id
      JOIN allgres_private.users tu ON tu.user_id = d.to_user_id), '[]'::jsonb)
  )
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_save_unit(p_unit_id uuid, p_name text, p_parent_unit_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_name text := btrim(COALESCE(p_name, ''));
  v_id uuid := p_unit_id;
BEGIN
  IF v_name = '' THEN
    RAISE EXCEPTION 'unit name required' USING ERRCODE = 'P0001';
  END IF;
  IF p_parent_unit_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM allgres_private.org_units WHERE unit_id = p_parent_unit_id) THEN
      RAISE EXCEPTION 'parent unit not found' USING ERRCODE = 'P0001';
    END IF;
    IF v_id IS NOT NULL AND (p_parent_unit_id = v_id OR EXISTS (
      WITH RECURSIVE below(unit_id) AS (
        SELECT unit_id FROM allgres_private.org_units WHERE parent_unit_id = v_id
        UNION
        SELECT c.unit_id FROM allgres_private.org_units c JOIN below b ON c.parent_unit_id = b.unit_id)
      SELECT 1 FROM below WHERE unit_id = p_parent_unit_id)) THEN
      RAISE EXCEPTION 'a unit cannot sit under itself or one of its own units' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO allgres_private.org_units (name, parent_unit_id) VALUES (v_name, p_parent_unit_id) RETURNING unit_id INTO v_id;
  ELSE
    UPDATE allgres_private.org_units SET name = v_name, parent_unit_id = p_parent_unit_id WHERE unit_id = v_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'unit not found' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  PERFORM allgres_private.audit('org.units.save', jsonb_build_object('unit_id', v_id, 'name', v_name));
  RETURN jsonb_build_object('ok', true, 'unit_id', v_id);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'a unit named "%" already exists', v_name USING ERRCODE = 'P0001';
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_delete_unit(p_unit_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_name text;
BEGIN
  DELETE FROM allgres_private.org_units WHERE unit_id = p_unit_id RETURNING name INTO v_name;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'unit not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('org.units.delete', jsonb_build_object('unit_id', p_unit_id, 'name', v_name));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_save_role(p_role_id uuid, p_name text, p_description text DEFAULT '')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_name text := btrim(COALESCE(p_name, ''));
  v_id uuid := p_role_id;
BEGIN
  IF v_name = '' THEN
    RAISE EXCEPTION 'role name required' USING ERRCODE = 'P0001';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO allgres_private.org_roles (name, description) VALUES (v_name, COALESCE(p_description, '')) RETURNING role_id INTO v_id;
  ELSE
    UPDATE allgres_private.org_roles SET name = v_name, description = COALESCE(p_description, '') WHERE role_id = v_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  PERFORM allgres_private.audit('org.roles.save', jsonb_build_object('role_id', v_id, 'name', v_name));
  RETURN jsonb_build_object('ok', true, 'role_id', v_id);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'a role named "%" already exists', v_name USING ERRCODE = 'P0001';
END;
$fn$;

-- Deleting a role also deletes the rules that name it as their decider and
-- the memberships that hold it (ON DELETE CASCADE above): requests those
-- rules already routed keep a dangling role, which only admins can decide.
CREATE OR REPLACE FUNCTION allgres_public.fn_org_delete_role(p_role_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_name text;
BEGIN
  DELETE FROM allgres_private.org_roles WHERE role_id = p_role_id RETURNING name INTO v_name;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('org.roles.delete', jsonb_build_object('role_id', p_role_id, 'name', v_name));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_add_membership(p_user_id uuid, p_role_id uuid, p_unit_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users WHERE user_id = p_user_id) THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.org_roles WHERE role_id = p_role_id) THEN
    RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0001';
  END IF;
  IF p_unit_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM allgres_private.org_units WHERE unit_id = p_unit_id) THEN
    RAISE EXCEPTION 'unit not found' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.org_memberships (user_id, role_id, unit_id)
  VALUES (p_user_id, p_role_id, p_unit_id)
  ON CONFLICT DO NOTHING
  RETURNING membership_id INTO v_id;
  IF v_id IS NULL THEN
    SELECT membership_id INTO v_id FROM allgres_private.org_memberships
    WHERE user_id = p_user_id AND role_id = p_role_id AND unit_id IS NOT DISTINCT FROM p_unit_id;
  END IF;
  PERFORM allgres_private.audit('org.memberships.add', jsonb_build_object(
    'user_id', p_user_id, 'role_id', p_role_id, 'unit_id', p_unit_id));
  RETURN jsonb_build_object('ok', true, 'membership_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_remove_membership(p_membership_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.org_memberships WHERE membership_id = p_membership_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'membership not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('org.memberships.remove', jsonb_build_object('membership_id', p_membership_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_save_rule(p_rule jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid := NULLIF(p_rule->>'rule_id', '')::uuid;
  v_applies text := p_rule->>'applies_to';
  v_group uuid := NULLIF(p_rule->>'match_agent_group_id', '')::uuid;
  v_kind text := NULLIF(btrim(COALESCE(p_rule->>'match_kind', '')), '');
  v_role uuid := NULLIF(p_rule->>'decider_role_id', '')::uuid;
  v_unit uuid := NULLIF(p_rule->>'decider_unit_id', '')::uuid;
  v_esc_secs bigint := NULLIF(p_rule->>'escalate_after_seconds', '')::bigint;
  v_esc_role uuid := NULLIF(p_rule->>'escalate_role_id', '')::uuid;
  v_priority int := COALESCE(NULLIF(p_rule->>'priority', '')::int, 100);
  v_name text := COALESCE(p_rule->>'name', '');
BEGIN
  IF v_applies IS NULL OR v_applies NOT IN ('approval', 'proposal') THEN
    RAISE EXCEPTION 'applies_to must be approval or proposal' USING ERRCODE = 'P0001';
  END IF;
  IF v_role IS NULL OR NOT EXISTS (SELECT 1 FROM allgres_private.org_roles WHERE role_id = v_role) THEN
    RAISE EXCEPTION 'decider role not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_unit IS NOT NULL AND NOT EXISTS (SELECT 1 FROM allgres_private.org_units WHERE unit_id = v_unit) THEN
    RAISE EXCEPTION 'decider unit not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_group IS NOT NULL AND NOT EXISTS (SELECT 1 FROM allgres_private.agent_groups WHERE group_id = v_group) THEN
    RAISE EXCEPTION 'agent group not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_esc_role IS NOT NULL AND NOT EXISTS (SELECT 1 FROM allgres_private.org_roles WHERE role_id = v_esc_role) THEN
    RAISE EXCEPTION 'escalation role not found' USING ERRCODE = 'P0001';
  END IF;
  IF (v_esc_secs IS NULL) <> (v_esc_role IS NULL) THEN
    RAISE EXCEPTION 'escalation needs both a time and a role' USING ERRCODE = 'P0001';
  END IF;
  IF v_esc_secs IS NOT NULL AND v_esc_secs <= 0 THEN
    RAISE EXCEPTION 'escalation time must be positive' USING ERRCODE = 'P0001';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO allgres_private.approval_rules (name, priority, applies_to, match_agent_group_id, match_kind,
      decider_role_id, decider_unit_id, escalate_after, escalate_role_id)
    VALUES (v_name, v_priority, v_applies, v_group, v_kind, v_role, v_unit,
      CASE WHEN v_esc_secs IS NULL THEN NULL ELSE make_interval(secs => v_esc_secs) END, v_esc_role)
    RETURNING rule_id INTO v_id;
  ELSE
    UPDATE allgres_private.approval_rules SET name = v_name, priority = v_priority, applies_to = v_applies,
      match_agent_group_id = v_group, match_kind = v_kind, decider_role_id = v_role, decider_unit_id = v_unit,
      escalate_after = CASE WHEN v_esc_secs IS NULL THEN NULL ELSE make_interval(secs => v_esc_secs) END,
      escalate_role_id = v_esc_role
    WHERE rule_id = v_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'rule not found' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  PERFORM allgres_private.audit('approval_rules.save', jsonb_build_object('rule_id', v_id, 'applies_to', v_applies));
  RETURN jsonb_build_object('ok', true, 'rule_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_delete_rule(p_rule_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.approval_rules WHERE rule_id = p_rule_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rule not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('approval_rules.delete', jsonb_build_object('rule_id', p_rule_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_add_delegation(
  p_from_user_id uuid, p_to_user_id uuid, p_valid_until timestamptz, p_valid_from timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_from timestamptz := COALESCE(p_valid_from, clock_timestamp());
BEGIN
  IF p_from_user_id = p_to_user_id THEN
    RAISE EXCEPTION 'a person cannot delegate to themselves' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users WHERE user_id = p_from_user_id)
     OR NOT EXISTS (SELECT 1 FROM allgres_private.users WHERE user_id = p_to_user_id) THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0001';
  END IF;
  IF p_valid_until IS NULL OR p_valid_until <= v_from THEN
    RAISE EXCEPTION 'valid_until must be after the start' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.approval_delegations (from_user_id, to_user_id, valid_from, valid_until)
  VALUES (p_from_user_id, p_to_user_id, v_from, p_valid_until)
  RETURNING delegation_id INTO v_id;
  PERFORM allgres_private.audit('approval_delegations.add', jsonb_build_object(
    'delegation_id', v_id, 'from_user_id', p_from_user_id, 'to_user_id', p_to_user_id, 'valid_until', p_valid_until));
  RETURN jsonb_build_object('ok', true, 'delegation_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_org_remove_delegation(p_delegation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.approval_delegations WHERE delegation_id = p_delegation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delegation not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('approval_delegations.remove', jsonb_build_object('delegation_id', p_delegation_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;
