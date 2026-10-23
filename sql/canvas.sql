-- Allgres control plane -- Canvas: groups, board positions, saved
-- configurations, the delegation ceiling, and per-task models.
--
-- Everything the Canvas page (/canvas, docs/canvas.md) changes lives here,
-- in PostgreSQL, the same as every other piece of durable state: the board
-- itself keeps nothing but the current selection and an undo list. Loaded
-- after sql/seed_data.sql and before sql/selftest.sql (src/lib.rs); every
-- function is LANGUAGE plpgsql/sql, so nothing here is resolved against the
-- catalog until it is called. The final ownership and REVOKE pass in
-- sql/grants_and_facade.sql covers these objects like any other.
--
-- Two deliberate non-uses of existing columns:
--
-- * agents.parent_agent_id is not the board's hierarchy. It is the system
--   agents' permission and prompt inheritance edge (control_plane.sql,
--   agent_has_permission), and an ordinary agent's is always NULL. A line
--   drawn on the board is an `agent` permission -- "may delegate to" --
--   which is exactly what `delegate` checks at run time.
-- * Groups carry no permissions. A team is how an operator arranges agents,
--   not a security boundary; what an agent may do is still only its own
--   permissions rows.

CREATE TABLE IF NOT EXISTS allgres_private.agent_groups (
  group_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL CHECK (btrim(name) <> ''),
  kind            text NOT NULL DEFAULT 'team' CHECK (kind IN ('team', 'division', 'project')),
  -- Groups nest (a division holding teams). fn_canvas_update_group refuses
  -- a parent that is the group itself or one of its own descendants, so the
  -- recursive walks below always terminate.
  parent_group_id uuid REFERENCES allgres_private.agent_groups(group_id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- One group per agent: the board draws an agent inside exactly one box.
CREATE TABLE IF NOT EXISTS allgres_private.agent_group_members (
  agent_id   uuid PRIMARY KEY REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  group_id   uuid NOT NULL REFERENCES allgres_private.agent_groups(group_id) ON DELETE CASCADE,
  added_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS agent_group_members_group_idx ON allgres_private.agent_group_members (group_id);

-- Absolute board coordinates. An item with no row is laid out by the board
-- from its delegation lines on load; dragging it writes one.
CREATE TABLE IF NOT EXISTS allgres_private.canvas_positions (
  item_kind  text NOT NULL CHECK (item_kind IN ('agent', 'group')),
  item_id    uuid NOT NULL,
  x          double precision NOT NULL,
  y          double precision NOT NULL,
  width      double precision CHECK (width IS NULL OR width > 0),
  height     double precision CHECK (height IS NULL OR height > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_kind, item_id)
);

-- A saved configuration: one group, everything nested in it, its agents'
-- policies and grants, and the delegation lines between them, as a jsonb
-- snapshot (fn_canvas_save_template documents the shape). Instantiating it
-- creates new agents through fn_create_agent; nothing points back here.
CREATE TABLE IF NOT EXISTS allgres_private.canvas_templates (
  template_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
  body               jsonb NOT NULL CHECK (jsonb_typeof(body) = 'object'),
  created_by_user_id uuid REFERENCES allgres_private.users(user_id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now()
);

-- Per-task model (Canvas "Allow a model per task"). Off by default, so an
-- agent runs on its own llm_config exactly as before unless an admin opts it
-- in. When on, fn_canvas_run may stamp tasks.llm_override on the root task it
-- creates, and fn_next_step layers that over the agent's default and any chat
-- preference for that one task only -- delegated children start from their
-- own agent's policy. A function or procedure llm_override still wins over
-- it, for the reason that column's own comment gives.
ALTER TABLE allgres_private.agents
  ADD COLUMN IF NOT EXISTS allow_task_model boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.tasks
  ADD COLUMN IF NOT EXISTS llm_override jsonb
  CHECK (llm_override IS NULL OR jsonb_typeof(llm_override) = 'object');

-- True when p_group is p_ancestor or nested anywhere under it.
CREATE OR REPLACE FUNCTION allgres_private.canvas_group_within(p_group uuid, p_ancestor uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $fn$
  WITH RECURSIVE up AS (
    SELECT group_id, parent_group_id FROM allgres_private.agent_groups WHERE group_id = p_group
    UNION
    SELECT g.group_id, g.parent_group_id
    FROM allgres_private.agent_groups g JOIN up ON g.group_id = up.parent_group_id
  )
  SELECT EXISTS (SELECT 1 FROM up WHERE group_id = p_ancestor)
$fn$;

-- Every agent that can hand work to p_agent_id, directly or through a chain
-- of `agent` grants: the agents above it on the board. UNION, not UNION ALL,
-- because delegation lines may form a cycle (A and B delegating to each
-- other is legal; max_delegation_depth bounds it at run time).
CREATE OR REPLACE FUNCTION allgres_private.canvas_superiors(p_agent_id uuid)
RETURNS TABLE (agent_id uuid)
LANGUAGE sql
STABLE
AS $fn$
  WITH RECURSIVE up(agent_id) AS (
    SELECT p.agent_id
    FROM allgres_private.permissions p
    JOIN allgres_private.agents t ON t.agent_id = p_agent_id
    WHERE p.resource_type = 'agent' AND lower(p.resource_ref) = lower(t.name)
    UNION
    SELECT p.agent_id
    FROM up
    JOIN allgres_private.agents t ON t.agent_id = up.agent_id
    JOIN allgres_private.permissions p
      ON p.resource_type = 'agent' AND lower(p.resource_ref) = lower(t.name)
  )
  SELECT agent_id FROM up WHERE agent_id <> p_agent_id
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.canvas_require_agent(p_agent_id uuid)
RETURNS allgres_private.agents
LANGUAGE plpgsql
AS $fn$
DECLARE
  a allgres_private.agents%ROWTYPE;
BEGIN
  SELECT * INTO a FROM allgres_private.agents WHERE agent_id = p_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;
  RETURN a;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.canvas_require_group(p_group_id uuid)
RETURNS allgres_private.agent_groups
LANGUAGE plpgsql
AS $fn$
DECLARE
  g allgres_private.agent_groups%ROWTYPE;
BEGIN
  SELECT * INTO g FROM allgres_private.agent_groups WHERE group_id = p_group_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'group not found' USING ERRCODE = 'P0001';
  END IF;
  RETURN g;
END;
$fn$;

-- p_base if free, else p_base_2, p_base_3, ... -- agents.name is UNIQUE and
-- a saved configuration can be placed more than once.
CREATE OR REPLACE FUNCTION allgres_private.canvas_free_agent_name(p_base text)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_name text := btrim(p_base);
  n int := 1;
BEGIN
  WHILE EXISTS (SELECT 1 FROM allgres_private.agents WHERE lower(name) = lower(v_name)) LOOP
    n := n + 1;
    v_name := btrim(p_base) || '_' || n;
  END LOOP;
  RETURN v_name;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.canvas_put_position(
  p_kind text, p_id uuid, p_pos jsonb
) RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF p_pos IS NULL OR jsonb_typeof(p_pos) <> 'object' OR NOT (p_pos ? 'x' AND p_pos ? 'y') THEN
    RETURN;
  END IF;
  INSERT INTO allgres_private.canvas_positions (item_kind, item_id, x, y, width, height)
  VALUES (p_kind, p_id, (p_pos->>'x')::float8, (p_pos->>'y')::float8,
          (p_pos->>'width')::float8, (p_pos->>'height')::float8)
  ON CONFLICT (item_kind, item_id) DO UPDATE
  SET x = EXCLUDED.x, y = EXCLUDED.y,
      width = COALESCE(EXCLUDED.width, canvas_positions.width),
      height = COALESCE(EXCLUDED.height, canvas_positions.height),
      updated_at = now();
END;
$fn$;

-- Everything the board needs besides agents.list, in one read.
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_state()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'ok', true,
    'groups', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'group_id', g.group_id, 'name', g.name, 'kind', g.kind,
        'parent_group_id', g.parent_group_id, 'updated_at', g.updated_at
      ) ORDER BY g.created_at)
      FROM allgres_private.agent_groups g
      WHERE g.name NOT LIKE 'selftest%'
    ), '[]'::jsonb),
    'members', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('agent_id', m.agent_id, 'group_id', m.group_id))
      FROM allgres_private.agent_group_members m
    ), '[]'::jsonb),
    'positions', COALESCE((
      SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'kind', c.item_kind, 'id', c.item_id, 'x', c.x, 'y', c.y,
        'width', c.width, 'height', c.height
      )))
      FROM allgres_private.canvas_positions c
    ), '[]'::jsonb),
    'templates', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'template_id', t.template_id, 'name', t.name, 'created_at', t.created_at,
        'agents', jsonb_array_length(COALESCE(t.body->'agents', '[]'::jsonb)),
        'groups', jsonb_array_length(COALESCE(t.body->'groups', '[]'::jsonb))
      ) ORDER BY t.name)
      FROM allgres_private.canvas_templates t
      WHERE t.name NOT LIKE 'selftest%'
    ), '[]'::jsonb)
  )
$fn$;

-- Moving a box is layout, not a change to what any agent may do, so it is
-- the one canvas write that leaves no audit_log row: a drag would otherwise
-- bury the grants and team changes an auditor is looking for.
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_save_positions(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  it jsonb;
  n int := 0;
BEGIN
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'items must be an array' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_array_length(p_items) > 1000 THEN
    RAISE EXCEPTION 'too many items in one save' USING ERRCODE = 'P0001';
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF it->>'kind' = 'agent' THEN
      PERFORM allgres_private.canvas_require_agent((it->>'id')::uuid);
    ELSIF it->>'kind' = 'group' THEN
      PERFORM allgres_private.canvas_require_group((it->>'id')::uuid);
    ELSE
      RAISE EXCEPTION 'unknown item kind: %', it->>'kind' USING ERRCODE = 'P0001';
    END IF;
    PERFORM allgres_private.canvas_put_position(it->>'kind', (it->>'id')::uuid, it);
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'saved', n);
END;
$fn$;

-- p_agent_ids, when given, move straight into the new group in the same
-- transaction (Canvas "Group selected").
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_create_group(
  p_name text, p_kind text DEFAULT 'team', p_parent_group_id uuid DEFAULT NULL, p_position jsonb DEFAULT NULL,
  p_agent_ids uuid[] DEFAULT '{}'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  IF p_parent_group_id IS NOT NULL THEN
    PERFORM allgres_private.canvas_require_group(p_parent_group_id);
  END IF;
  INSERT INTO allgres_private.agent_groups (name, kind, parent_group_id)
  VALUES (btrim(COALESCE(p_name, '')), COALESCE(NULLIF(p_kind, ''), 'team'), p_parent_group_id)
  RETURNING group_id INTO v_id;
  PERFORM allgres_private.canvas_put_position('group', v_id, p_position);
  PERFORM allgres_private.audit('canvas.groups.create', jsonb_build_object(
    'group_id', v_id, 'name', btrim(p_name), 'kind', COALESCE(NULLIF(p_kind, ''), 'team'),
    'parent_group_id', p_parent_group_id
  ));
  FOR i IN 1..COALESCE(array_length(p_agent_ids, 1), 0) LOOP
    PERFORM allgres_public.fn_canvas_set_group_member(p_agent_ids[i], v_id);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'group_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_update_group(
  p_group_id uuid, p_name text DEFAULT NULL, p_kind text DEFAULT NULL,
  p_parent_group_id uuid DEFAULT NULL, p_clear_parent boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  g allgres_private.agent_groups%ROWTYPE;
BEGIN
  g := allgres_private.canvas_require_group(p_group_id);
  IF p_parent_group_id IS NOT NULL THEN
    PERFORM allgres_private.canvas_require_group(p_parent_group_id);
    IF allgres_private.canvas_group_within(p_parent_group_id, p_group_id) THEN
      RAISE EXCEPTION 'a group cannot be placed inside itself or one of its own groups' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  UPDATE allgres_private.agent_groups
  SET name = COALESCE(NULLIF(btrim(p_name), ''), name),
      kind = COALESCE(NULLIF(p_kind, ''), kind),
      parent_group_id = CASE
        WHEN p_clear_parent THEN NULL
        WHEN p_parent_group_id IS NOT NULL THEN p_parent_group_id
        ELSE parent_group_id END,
      updated_at = now()
  WHERE group_id = p_group_id;
  PERFORM allgres_private.audit('canvas.groups.update', jsonb_strip_nulls(jsonb_build_object(
    'group_id', p_group_id, 'name', NULLIF(btrim(p_name), ''), 'kind', NULLIF(p_kind, ''),
    'parent_group_id', p_parent_group_id, 'clear_parent', CASE WHEN p_clear_parent THEN true END
  )));
  RETURN jsonb_build_object('ok', true, 'group_id', p_group_id);
END;
$fn$;

-- Deleting a box never deletes an agent: its agents and nested groups move
-- up to the group that held it (or out of any group, at the top level).
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_delete_group(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  g allgres_private.agent_groups%ROWTYPE;
  v_moved int;
BEGIN
  g := allgres_private.canvas_require_group(p_group_id);
  IF g.parent_group_id IS NULL THEN
    DELETE FROM allgres_private.agent_group_members WHERE group_id = p_group_id;
  ELSE
    UPDATE allgres_private.agent_group_members SET group_id = g.parent_group_id, added_at = now()
    WHERE group_id = p_group_id;
  END IF;
  GET DIAGNOSTICS v_moved = ROW_COUNT;
  UPDATE allgres_private.agent_groups SET parent_group_id = g.parent_group_id, updated_at = now()
  WHERE parent_group_id = p_group_id;
  DELETE FROM allgres_private.canvas_positions WHERE item_kind = 'group' AND item_id = p_group_id;
  DELETE FROM allgres_private.agent_groups WHERE group_id = p_group_id;
  PERFORM allgres_private.audit('canvas.groups.delete', jsonb_build_object(
    'group_id', p_group_id, 'name', g.name, 'members', v_moved, 'moved_to', g.parent_group_id
  ));
  RETURN jsonb_build_object('ok', true, 'moved_to', g.parent_group_id);
END;
$fn$;

-- Folds p_source into p_target: its agents and nested groups move to the
-- target, and the source box is removed. Delegation lines are untouched --
-- merging teams changes where agents sit, not who may delegate to whom.
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_merge_groups(p_source_group_id uuid, p_target_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  s allgres_private.agent_groups%ROWTYPE;
  t allgres_private.agent_groups%ROWTYPE;
  v_moved int;
BEGIN
  s := allgres_private.canvas_require_group(p_source_group_id);
  t := allgres_private.canvas_require_group(p_target_group_id);
  IF allgres_private.canvas_group_within(p_target_group_id, p_source_group_id) THEN
    RAISE EXCEPTION 'cannot merge a group into itself or one of its own groups' USING ERRCODE = 'P0001';
  END IF;
  UPDATE allgres_private.agent_group_members SET group_id = p_target_group_id, added_at = now()
  WHERE group_id = p_source_group_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;
  UPDATE allgres_private.agent_groups SET parent_group_id = p_target_group_id, updated_at = now()
  WHERE parent_group_id = p_source_group_id;
  DELETE FROM allgres_private.canvas_positions WHERE item_kind = 'group' AND item_id = p_source_group_id;
  DELETE FROM allgres_private.agent_groups WHERE group_id = p_source_group_id;
  UPDATE allgres_private.agent_groups SET updated_at = now() WHERE group_id = p_target_group_id;
  PERFORM allgres_private.audit('canvas.groups.merge', jsonb_build_object(
    'source_group_id', p_source_group_id, 'source_name', s.name,
    'target_group_id', p_target_group_id, 'target_name', t.name, 'members', v_moved
  ));
  RETURN jsonb_build_object('ok', true, 'group_id', p_target_group_id, 'moved', v_moved);
END;
$fn$;

-- p_group_id NULL takes the agent out of any group.
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_set_group_member(p_agent_id uuid, p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  a allgres_private.agents%ROWTYPE;
  v_before uuid;
BEGIN
  a := allgres_private.canvas_require_agent(p_agent_id);
  IF a.is_system THEN
    RAISE EXCEPTION 'system agents stay in their own frame and cannot join a group' USING ERRCODE = 'P0001';
  END IF;
  SELECT group_id INTO v_before FROM allgres_private.agent_group_members WHERE agent_id = p_agent_id;
  IF v_before IS NOT DISTINCT FROM p_group_id THEN
    RETURN jsonb_build_object('ok', true, 'group_id', p_group_id, 'changed', false);
  END IF;
  IF p_group_id IS NULL THEN
    DELETE FROM allgres_private.agent_group_members WHERE agent_id = p_agent_id;
  ELSE
    PERFORM allgres_private.canvas_require_group(p_group_id);
    INSERT INTO allgres_private.agent_group_members (agent_id, group_id) VALUES (p_agent_id, p_group_id)
    ON CONFLICT (agent_id) DO UPDATE SET group_id = EXCLUDED.group_id, added_at = now();
  END IF;
  PERFORM allgres_private.audit('canvas.groups.set_member', jsonb_build_object(
    'agent_id', p_agent_id, 'name', a.name, 'group_id', p_group_id, 'previous_group_id', v_before
  ));
  RETURN jsonb_build_object('ok', true, 'group_id', p_group_id, 'previous_group_id', v_before, 'changed', true);
END;
$fn$;

-- Every agent p_agent_id can hand work to, directly or through a chain of
-- `agent` grants -- the mirror image of canvas_superiors, plus p_agent_id
-- itself. UNION for the same cycle reason.
CREATE OR REPLACE FUNCTION allgres_private.canvas_subordinates_and_self(p_agent_id uuid)
RETURNS TABLE (agent_id uuid)
LANGUAGE sql
STABLE
AS $fn$
  WITH RECURSIVE down(agent_id) AS (
    SELECT p_agent_id
    UNION
    SELECT x.agent_id
    FROM down
    JOIN allgres_private.permissions p
      ON p.agent_id = down.agent_id AND p.resource_type = 'agent'
    JOIN allgres_private.agents x ON lower(x.name) = lower(p.resource_ref)
  )
  SELECT agent_id FROM down
$fn$;

-- The delegation ceiling, seen from the line rather than from one grant
-- (fn_canvas_grant): drawing p_from -> p_to puts p_from and everything
-- above it on top of p_to and everything below p_to. Every view, function,
-- procedure, or HTTP host held (own or inherited) anywhere in that lower
-- part must therefore already be held by every agent in the upper part,
-- or the line would let p_from reach, through p_to, what it was never
-- granted (D1). Returns one row per (upper agent, missing grant); empty
-- means the line stays within the ceiling.
CREATE OR REPLACE FUNCTION allgres_private.canvas_delegation_gaps(p_from_agent_id uuid, p_to_agent_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $fn$
  WITH upper_part AS (
    SELECT p_from_agent_id AS agent_id
    UNION
    SELECT s.agent_id FROM allgres_private.canvas_superiors(p_from_agent_id) s
  ),
  held AS (
    SELECT DISTINCT ty AS resource_type,
           CASE WHEN ty = 'http_host' THEN lower(ref) ELSE ref END AS resource_ref
    FROM allgres_private.canvas_subordinates_and_self(p_to_agent_id) d
    CROSS JOIN unnest(ARRAY['view', 'function', 'procedure', 'http_host']) ty
    CROSS JOIN LATERAL unnest(allgres_private.agent_permission_refs(d.agent_id, ty)) ref
    -- Legacy/pre-registration outbound Function rows are inert, and cannot
    -- be granted upward to close a gap: these Functions require a procedure.
    WHERE ty <> 'function' OR allgres_private.function_ref_directly_grantable(ref)
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'agent_id', u.agent_id, 'name', x.name,
           'type', h.resource_type, 'ref', h.resource_ref
         ) ORDER BY x.name, h.resource_type, h.resource_ref), '[]'::jsonb)
  FROM upper_part u
  JOIN allgres_private.agents x ON x.agent_id = u.agent_id
  CROSS JOIN held h
  WHERE NOT allgres_private.agent_has_permission(u.agent_id, h.resource_type, h.resource_ref)
$fn$;

-- The delegation rules, enforced in exactly one place: fn_grant_permission
-- calls this for every `agent` grant, so SQL, the dashboard's
-- permissions.grant, Canvas lines, and Canvas templates all get the same
-- answer. p_from_agent_id may delegate to the agent named p_to_ref only if:
--   * the target exists (otherwise a grant could be written first and the
--     agent created later, past every check below) and is not p_from itself;
--   * the target is not a system agent (D2). A system agent runs with
--     platform-level permissions (fixer, creator, self_improve, ...), so a
--     line into it would be a privilege escalation for whoever draws it;
--   * the delegation ceiling holds (D1, canvas_delegation_gaps): refused,
--     with every missing grant listed in the error detail, when the target
--     (or anything below it) holds something p_from or anything above
--     p_from lacks. Grant it upward first (fn_canvas_grant with
--     p_include_superiors), then delegate.
-- A system agent as the *sender* is not refused here: system agents are
-- configured over direct SQL by design (forbid_system_agent_edit keeps
-- them out of the dashboard, and Canvas refuses them as its own rule).
-- Returns the target's stored name, which fn_grant_permission writes as the
-- grant's resource_ref (so ' FIXER ' is never stored for 'fixer').
CREATE OR REPLACE FUNCTION allgres_private.check_delegation(p_from_agent_id uuid, p_to_ref text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  f allgres_private.agents%ROWTYPE;
  t allgres_private.agents%ROWTYPE;
  v_gaps jsonb;
  v_summary text;
BEGIN
  SELECT * INTO f FROM allgres_private.agents WHERE agent_id = p_from_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;
  -- Names are unique ignoring case and surrounding spaces
  -- (agents_name_ci_key), so this finds at most one agent: the one
  -- agent_has_permission and canvas_subordinates_and_self resolve the grant to.
  SELECT * INTO t FROM allgres_private.agents
  WHERE lower(name) = lower(btrim(p_to_ref));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cannot delegate to %: no such agent', p_to_ref USING ERRCODE = 'P0001';
  END IF;
  IF f.agent_id = t.agent_id THEN
    RAISE EXCEPTION 'an agent cannot delegate to itself' USING ERRCODE = 'P0001';
  END IF;
  IF t.is_system THEN
    RAISE EXCEPTION 'system agents run the platform itself and cannot take delegated work (% -> %)', f.name, t.name
      USING ERRCODE = 'P0001';
  END IF;

  v_gaps := allgres_private.canvas_delegation_gaps(f.agent_id, t.agent_id);
  IF jsonb_array_length(v_gaps) > 0 THEN
    SELECT string_agg(format('%s lacks %s %s', e->>'name', e->>'type', e->>'ref'), '; ')
    INTO v_summary
    FROM (SELECT e FROM jsonb_array_elements(v_gaps) e LIMIT 5) q;
    IF jsonb_array_length(v_gaps) > 5 THEN
      v_summary := v_summary || format('; and %s more', jsonb_array_length(v_gaps) - 5);
    END IF;
    RAISE EXCEPTION 'delegation exceeds the ceiling: % can do things % cannot (%). Grant them to % first, or remove them from %',
      t.name, f.name, v_summary, f.name, t.name
      USING ERRCODE = 'P0001', DETAIL = v_gaps::text;
  END IF;
  RETURN t.name;
END;
$fn$;

-- What a non-agent grant may name, and how it is stored. Called by
-- fn_grant_permission and fn_canvas_grant before anything else.
--  * http_host refs are stored lower-cased and trimmed, the way url_host
--    reports a host, so revoke and the ceiling check see one spelling.
--  * a direct `function` grant may name a built-in (http_get, http_request)
--    or a PL/pgSQL Function. A fixed-URL http_get or an MCP Function runs
--    only through a Procedure that binds it -- the execution guard requires
--    an http_host grant for any outbound call without a procedure -- so a
--    direct grant of one would never work; it is refused here instead.
CREATE OR REPLACE FUNCTION allgres_private.check_grant_target(p_type text, p_ref text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_handler text;
BEGIN
  IF p_type = 'http_host' THEN
    RETURN lower(btrim(p_ref));
  END IF;
  IF p_type = 'function' AND NOT allgres_private.function_ref_directly_grantable(p_ref) THEN
    SELECT handler INTO v_handler FROM allgres_private.functions
    WHERE lower(name) = lower(btrim(p_ref)) AND handler <> 'plpgsql'
    LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION '% is % Function and cannot be granted directly; bind it via a procedure and grant that procedure',
        btrim(p_ref), CASE v_handler WHEN 'mcp_call' THEN 'an MCP' ELSE 'a fixed-URL http_get' END
        USING ERRCODE = 'P0001',
              HINT = 'functions.bind attaches it to a procedure; then grant the procedure (permission type procedure).';
    END IF;
  END IF;
  RETURN p_ref;
END;
$fn$;

-- The other half of the ceiling (audit #2): once a line exists, a new
-- view/function/procedure/http_host grant to the agent below it must already
-- be held by every agent above it, or the line would carry it upward to
-- agents that were never granted it. fn_grant_permission calls this for
-- every non-agent grant (the single enforcement point, as check_delegation
-- is for lines); fn_canvas_grant calls it once for the whole set it grants
-- together (the agent plus each superior that lacks it), so a chain or a
-- cycle of superiors can be granted in one step.
--
-- p_agent_ids are treated as already holding the grant. Agents that inherit
-- from one of them through parent_agent_id (system agents) receive it too,
-- so their superiors count as well. Raises with a JSON DETAIL of
-- [{agent_id, name, type, ref}], the shape canvas_delegation_gaps uses.
CREATE OR REPLACE FUNCTION allgres_private.check_grant_ceiling(p_agent_ids uuid[], p_type text, p_ref text)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_ref text := CASE WHEN p_type = 'http_host' THEN lower(btrim(p_ref)) ELSE p_ref END;
  v_missing jsonb;
  v_summary text;
  v_names text;
BEGIN
  IF p_type IS NULL OR p_type NOT IN ('view', 'function', 'procedure', 'http_host') THEN
    RETURN;
  END IF;
  WITH RECURSIVE receiving(agent_id) AS (
    SELECT unnest(p_agent_ids)
    UNION
    SELECT a.agent_id FROM allgres_private.agents a JOIN receiving r ON a.parent_agent_id = r.agent_id
  ),
  above AS (
    SELECT DISTINCT s.agent_id
    FROM receiving r
    CROSS JOIN LATERAL allgres_private.canvas_superiors(r.agent_id) s
    WHERE s.agent_id NOT IN (SELECT agent_id FROM receiving)
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'agent_id', x.agent_id, 'name', x.name, 'type', p_type, 'ref', v_ref) ORDER BY x.name), '[]'::jsonb)
  INTO v_missing
  FROM above u
  JOIN allgres_private.agents x ON x.agent_id = u.agent_id
  WHERE NOT allgres_private.agent_has_permission(u.agent_id, p_type, v_ref);

  IF jsonb_array_length(v_missing) > 0 THEN
    SELECT string_agg(name, ', ' ORDER BY name) INTO v_names FROM allgres_private.agents WHERE agent_id = ANY (p_agent_ids);
    SELECT string_agg(e->>'name', ', ') INTO v_summary
    FROM (SELECT e FROM jsonb_array_elements(v_missing) e LIMIT 5) q;
    IF jsonb_array_length(v_missing) > 5 THEN
      v_summary := v_summary || format(', and %s more', jsonb_array_length(v_missing) - 5);
    END IF;
    RAISE EXCEPTION 'grant exceeds the ceiling: % works under agents that lack % % (%). Grant it to them first (Canvas offers this in one step), or remove the delegation line',
      v_names, p_type, v_ref, v_summary
      USING ERRCODE = 'P0001', DETAIL = v_missing::text;
  END IF;
END;
$fn$;

-- A line on the board: p_from may delegate to p_to. Stored as the same
-- `agent` permission the Agents page and permissions.grant write, through
-- fn_grant_permission, which applies the D1/D2 rules (check_delegation);
-- they are not repeated here. Template instantiation goes through
-- fn_grant_permission too. The one Canvas-only rule: a system agent cannot
-- be given lines from the board at all, as with the rest of its settings.
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_add_delegation(p_from_agent_id uuid, p_to_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  f allgres_private.agents%ROWTYPE;
  t allgres_private.agents%ROWTYPE;
BEGIN
  f := allgres_private.canvas_require_agent(p_from_agent_id);
  t := allgres_private.canvas_require_agent(p_to_agent_id);
  IF f.is_system AND NOT t.is_system THEN
    RAISE EXCEPTION 'system agents cannot be given delegation lines from the board (% -> %)', f.name, t.name
      USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_public.fn_grant_permission(f.agent_id, 'agent', t.name);
  RETURN jsonb_build_object('ok', true, 'from', f.name, 'to', t.name);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_remove_delegation(p_from_agent_id uuid, p_to_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  f allgres_private.agents%ROWTYPE;
  t allgres_private.agents%ROWTYPE;
BEGIN
  f := allgres_private.canvas_require_agent(p_from_agent_id);
  t := allgres_private.canvas_require_agent(p_to_agent_id);
  DELETE FROM allgres_private.permissions
  WHERE agent_id = f.agent_id AND resource_type = 'agent' AND lower(resource_ref) = lower(t.name);
  PERFORM allgres_private.audit('permissions.revoke', jsonb_build_object('agent_id', f.agent_id, 'type', 'agent', 'ref', t.name));
  RETURN jsonb_build_object('ok', true, 'from', f.name, 'to', t.name);
END;
$fn$;

-- The delegation ceiling: an agent may be given a view, function,
-- procedure, or HTTP host only if every agent above it on the board (every
-- agent that can delegate to it, directly or through others) already holds
-- it too. Without this, a lead could route work through a worker to reach
-- something the lead itself was never granted. With p_include_superiors the
-- missing agents are granted it in the same transaction; otherwise nothing
-- changes and the gap is returned for the board to ask about.
--
-- This is the Canvas grant path's own rule. permissions.grant (Agents page,
-- SQL) is the operator's unrestricted tool and is unchanged.
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_grant(
  p_agent_id uuid, p_type text, p_ref text, p_include_superiors boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  a allgres_private.agents%ROWTYPE;
  v_ref text := btrim(COALESCE(p_ref, ''));
  v_missing jsonb;
  m record;
BEGIN
  a := allgres_private.canvas_require_agent(p_agent_id);
  IF p_type IS NULL OR p_type NOT IN ('view', 'function', 'procedure', 'http_host') THEN
    RAISE EXCEPTION 'canvas grants views, functions, procedures, and HTTP hosts; draw a line to grant delegation' USING ERRCODE = 'P0001';
  END IF;
  IF v_ref = '' THEN
    RAISE EXCEPTION 'grant ref required' USING ERRCODE = 'P0001';
  END IF;
  v_ref := allgres_private.check_grant_target(p_type, v_ref);

  SELECT COALESCE(jsonb_agg(jsonb_build_object('agent_id', s.agent_id, 'name', x.name, 'is_system', x.is_system) ORDER BY x.name), '[]'::jsonb)
  INTO v_missing
  FROM allgres_private.canvas_superiors(p_agent_id) s
  JOIN allgres_private.agents x ON x.agent_id = s.agent_id
  WHERE NOT allgres_private.agent_has_permission(s.agent_id, p_type, v_ref);

  IF jsonb_array_length(v_missing) > 0 AND NOT COALESCE(p_include_superiors, false) THEN
    RETURN jsonb_build_object('ok', true, 'applied', false, 'missing', v_missing);
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_missing) e WHERE (e->>'is_system')::boolean) THEN
    RAISE EXCEPTION 'an agent above this one is a system agent, whose grants cannot be changed here' USING ERRCODE = 'P0001';
  END IF;

  -- Checked once for the whole set (fn_grant_permission would check each
  -- row against superiors not granted yet), then written row by row.
  PERFORM allgres_private.check_grant_ceiling(
    ARRAY(SELECT (e->>'agent_id')::uuid FROM jsonb_array_elements(v_missing) e) || p_agent_id,
    p_type, v_ref);
  FOR m IN SELECT (e->>'agent_id')::uuid AS agent_id FROM jsonb_array_elements(v_missing) e LOOP
    PERFORM allgres_private.insert_permission(m.agent_id, p_type, v_ref);
  END LOOP;
  PERFORM allgres_private.insert_permission(p_agent_id, p_type, v_ref);
  RETURN jsonb_build_object('ok', true, 'applied', true, 'also_granted', v_missing);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_task_model_allowed(p_agent_id uuid, p_allowed boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  UPDATE allgres_private.agents SET allow_task_model = COALESCE(p_allowed, false), updated_at = now()
  WHERE agent_id = p_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('agents.set_task_model', jsonb_build_object('agent_id', p_agent_id, 'allowed', COALESCE(p_allowed, false)));
  RETURN jsonb_build_object('ok', true, 'allow_task_model', COALESCE(p_allowed, false));
END;
$fn$;

-- Starts a session like `run`, optionally on a different model for this one
-- task. The provider must be an enabled chat provider row; the endpoint and
-- key still come only from that row (sanitize_llm_config).
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_run(
  p_agent_id uuid, p_goal text, p_provider text DEFAULT NULL, p_model text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  a allgres_private.agents%ROWTYPE;
  v_created jsonb;
  v_override jsonb;
BEGIN
  a := allgres_private.canvas_require_agent(p_agent_id);
  IF NULLIF(btrim(p_model), '') IS NOT NULL OR NULLIF(btrim(p_provider), '') IS NOT NULL THEN
    IF NOT a.allow_task_model THEN
      RAISE EXCEPTION 'this agent runs every task on its own model; turn on "Allow a model per task" first' USING ERRCODE = 'P0001';
    END IF;
    IF NULLIF(btrim(p_model), '') IS NULL THEN
      RAISE EXCEPTION 'model required' USING ERRCODE = 'P0001';
    END IF;
    IF NULLIF(btrim(p_provider), '') IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM allgres_private.llm_providers
      WHERE name = btrim(p_provider) AND is_enabled AND purpose = 'chat'
    ) THEN
      RAISE EXCEPTION 'provider not found or not enabled: %', btrim(p_provider) USING ERRCODE = 'P0001';
    END IF;
    v_override := allgres_private.sanitize_llm_config(jsonb_build_object(
      'provider', NULLIF(btrim(p_provider), ''), 'model', btrim(p_model)
    ));
  END IF;
  v_created := allgres_public.fn_create_session(p_agent_id, p_goal);
  IF v_override IS NOT NULL THEN
    UPDATE allgres_private.tasks SET llm_override = v_override
    WHERE task_id = (v_created->>'task_id')::uuid;
  END IF;
  PERFORM allgres_private.audit('canvas.run', jsonb_strip_nulls(jsonb_build_object(
    'agent_id', p_agent_id, 'session_id', v_created->>'session_id', 'llm_override', v_override
  )));
  RETURN v_created || jsonb_strip_nulls(jsonb_build_object('llm_override', v_override));
END;
$fn$;

-- body: {
--   "groups":      [{"key","name","kind","parent_key","x","y","width","height"}],
--   "agents":      [{"key","name","system_prompt","llm_config","autonomy_level",
--                    "allow_task_model","max_steps","max_retries",
--                    "max_concurrent_tasks","max_turn_seconds",
--                    "max_delegation_depth","max_session_tasks",
--                    "group_key","x","y","permissions":[{"type","ref"}]}],
--   "delegations": [{"from_key","to_key"}]
-- }
-- Coordinates are relative to the saved group's own top-left corner, so
-- the configuration lands wherever it is dropped. Grants to agents outside
-- the group are dropped from the delegation list (the receiving board may
-- not have them); every other grant is kept as is.
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_save_template(p_name text, p_group_id uuid, p_user_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  root allgres_private.agent_groups%ROWTYPE;
  ox float8;
  oy float8;
  v_body jsonb;
  v_id uuid;
BEGIN
  root := allgres_private.canvas_require_group(p_group_id);
  IF btrim(COALESCE(p_name, '')) = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = 'P0001';
  END IF;
  SELECT x, y INTO ox, oy FROM allgres_private.canvas_positions WHERE item_kind = 'group' AND item_id = p_group_id;
  ox := COALESCE(ox, 0);
  oy := COALESCE(oy, 0);

  WITH RECURSIVE tree AS (
    SELECT g.*, 0 AS depth FROM allgres_private.agent_groups g WHERE g.group_id = p_group_id
    UNION ALL
    SELECT g.*, tree.depth + 1 FROM allgres_private.agent_groups g JOIN tree ON g.parent_group_id = tree.group_id
  ),
  members AS (
    SELECT a.*, m.group_id
    FROM allgres_private.agent_group_members m
    JOIN tree USING (group_id)
    JOIN allgres_private.agents a ON a.agent_id = m.agent_id
    WHERE NOT a.is_system
  )
  SELECT jsonb_build_object(
    'groups', COALESCE((
      SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'key', t.group_id, 'name', t.name, 'kind', t.kind,
        'parent_key', CASE WHEN t.group_id = p_group_id THEN NULL ELSE t.parent_group_id END,
        'x', c.x - ox, 'y', c.y - oy, 'width', c.width, 'height', c.height
      )) ORDER BY t.depth, t.created_at)
      FROM tree t
      LEFT JOIN allgres_private.canvas_positions c ON c.item_kind = 'group' AND c.item_id = t.group_id
    ), '[]'::jsonb),
    'agents', COALESCE((
      SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'key', mb.agent_id, 'name', mb.name, 'system_prompt', p.system_prompt,
        'llm_config', p.llm_config, 'autonomy_level', mb.autonomy_level,
        'allow_task_model', mb.allow_task_model,
        'max_steps', p.max_steps, 'max_retries', p.max_retries,
        'max_concurrent_tasks', p.max_concurrent_tasks, 'max_turn_seconds', p.max_turn_seconds,
        'max_delegation_depth', p.max_delegation_depth, 'max_session_tasks', p.max_session_tasks,
        'group_key', mb.group_id, 'x', c.x - ox, 'y', c.y - oy,
        'permissions', COALESCE((
          SELECT jsonb_agg(jsonb_build_object('type', x.resource_type, 'ref', x.resource_ref)
                 ORDER BY x.resource_type, x.resource_ref)
          FROM allgres_private.permissions x
          WHERE x.agent_id = mb.agent_id AND x.resource_type <> 'agent'
        ), '[]'::jsonb)
      )) ORDER BY mb.name)
      FROM members mb
      JOIN allgres_private.policies p ON p.agent_id = mb.agent_id
      LEFT JOIN allgres_private.canvas_positions c ON c.item_kind = 'agent' AND c.item_id = mb.agent_id
    ), '[]'::jsonb),
    'delegations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('from_key', f.agent_id, 'to_key', t.agent_id) ORDER BY f.name, t.name)
      FROM members f
      JOIN allgres_private.permissions x ON x.agent_id = f.agent_id AND x.resource_type = 'agent'
      JOIN members t ON lower(t.name) = lower(x.resource_ref)
    ), '[]'::jsonb)
  ) INTO v_body;

  IF jsonb_array_length(v_body->'agents') = 0 THEN
    RAISE EXCEPTION 'this group has no agents to save' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.canvas_templates (name, body, created_by_user_id)
  VALUES (btrim(p_name), v_body, p_user_id)
  RETURNING template_id INTO v_id;
  PERFORM allgres_private.audit('canvas.templates.save', jsonb_build_object(
    'template_id', v_id, 'name', btrim(p_name), 'group_id', p_group_id,
    'agents', jsonb_array_length(v_body->'agents')
  ));
  RETURN jsonb_build_object('ok', true, 'template_id', v_id);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'a saved configuration named "%" already exists', btrim(p_name) USING ERRCODE = 'P0001';
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_delete_template(p_template_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_name text;
BEGIN
  DELETE FROM allgres_private.canvas_templates WHERE template_id = p_template_id RETURNING name INTO v_name;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'saved configuration not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('canvas.templates.delete', jsonb_build_object('template_id', p_template_id, 'name', v_name));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Places a saved configuration with its top-left corner at (p_x, p_y),
-- optionally inside p_parent_group_id. Every agent is new (fn_create_agent,
-- its own PostgreSQL role, its own audit row); a name already taken gets a
-- _2, _3 suffix. All of it is one transaction.
CREATE OR REPLACE FUNCTION allgres_public.fn_canvas_instantiate_template(
  p_template_id uuid, p_x float8 DEFAULT 0, p_y float8 DEFAULT 0, p_parent_group_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  tpl allgres_private.canvas_templates%ROWTYPE;
  gmap jsonb := '{}'::jsonb;
  amap jsonb := '{}'::jsonb;
  g jsonb;
  a jsonb;
  d jsonb;
  pm jsonb;
  v_gid uuid;
  v_aid uuid;
  v_root uuid;
  v_name text;
BEGIN
  SELECT * INTO tpl FROM allgres_private.canvas_templates WHERE template_id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'saved configuration not found' USING ERRCODE = 'P0001';
  END IF;
  IF p_parent_group_id IS NOT NULL THEN
    PERFORM allgres_private.canvas_require_group(p_parent_group_id);
  END IF;

  -- Groups are stored parent-first (fn_canvas_save_template orders them by
  -- depth), so one pass resolves every parent_key.
  FOR g IN SELECT * FROM jsonb_array_elements(COALESCE(tpl.body->'groups', '[]'::jsonb)) LOOP
    INSERT INTO allgres_private.agent_groups (name, kind, parent_group_id)
    VALUES (g->>'name', COALESCE(g->>'kind', 'team'),
            CASE WHEN g ? 'parent_key' THEN (gmap->>(g->>'parent_key'))::uuid ELSE p_parent_group_id END)
    RETURNING group_id INTO v_gid;
    v_root := COALESCE(v_root, v_gid);
    gmap := gmap || jsonb_build_object(g->>'key', v_gid);
    IF g ? 'x' THEN
      PERFORM allgres_private.canvas_put_position('group', v_gid, jsonb_strip_nulls(jsonb_build_object(
        'x', p_x + (g->>'x')::float8, 'y', p_y + (g->>'y')::float8,
        'width', g->'width', 'height', g->'height'
      )));
    END IF;
  END LOOP;

  FOR a IN SELECT * FROM jsonb_array_elements(COALESCE(tpl.body->'agents', '[]'::jsonb)) LOOP
    v_name := allgres_private.canvas_free_agent_name(a->>'name');
    v_aid := (allgres_public.fn_create_agent(v_name, a->>'system_prompt')->>'agent_id')::uuid;
    amap := amap || jsonb_build_object(a->>'key', v_aid);
    PERFORM allgres_public.fn_set_policy(
      v_aid, NULL, (a->>'max_steps')::int, (a->>'max_retries')::int,
      COALESCE(a->'llm_config', '{}'::jsonb), (a->>'max_concurrent_tasks')::int,
      -- jsonb_strip_nulls dropped a NULL ("no cap") max_turn_seconds.
      (a->>'max_turn_seconds')::int, NOT (a ? 'max_turn_seconds'),
      (a->>'max_delegation_depth')::int, (a->>'max_session_tasks')::int
    );
    IF a ? 'autonomy_level' THEN
      PERFORM allgres_public.fn_set_agent_autonomy(v_aid, a->>'autonomy_level');
    END IF;
    IF COALESCE((a->>'allow_task_model')::boolean, false) THEN
      UPDATE allgres_private.agents SET allow_task_model = true WHERE agent_id = v_aid;
    END IF;
    FOR pm IN SELECT * FROM jsonb_array_elements(COALESCE(a->'permissions', '[]'::jsonb)) LOOP
      PERFORM allgres_public.fn_grant_permission(v_aid, pm->>'type', pm->>'ref');
    END LOOP;
    IF a ? 'group_key' AND gmap ? (a->>'group_key') THEN
      INSERT INTO allgres_private.agent_group_members (agent_id, group_id)
      VALUES (v_aid, (gmap->>(a->>'group_key'))::uuid);
    END IF;
    IF a ? 'x' THEN
      PERFORM allgres_private.canvas_put_position('agent', v_aid, jsonb_build_object(
        'x', p_x + (a->>'x')::float8, 'y', p_y + (a->>'y')::float8
      ));
    END IF;
  END LOOP;

  FOR d IN SELECT * FROM jsonb_array_elements(COALESCE(tpl.body->'delegations', '[]'::jsonb)) LOOP
    IF amap ? (d->>'from_key') AND amap ? (d->>'to_key') THEN
      PERFORM allgres_public.fn_canvas_add_delegation((amap->>(d->>'from_key'))::uuid, (amap->>(d->>'to_key'))::uuid);
    END IF;
  END LOOP;

  PERFORM allgres_private.audit('canvas.templates.instantiate', jsonb_build_object(
    'template_id', p_template_id, 'name', tpl.name, 'group_id', v_root,
    'agent_ids', (SELECT jsonb_agg(value) FROM jsonb_each(amap))
  ));
  RETURN jsonb_build_object(
    'ok', true, 'group_id', v_root,
    'agent_ids', COALESCE((SELECT jsonb_agg(value) FROM jsonb_each(amap)), '[]'::jsonb)
  );
END;
$fn$;
