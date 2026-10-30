-- Copy an agent (docs/agent-clone.md). The copy is a new agent with its own
-- PostgreSQL role and its own audit entry; everything that is *setup* is
-- copied, nothing that is *history* or *wiring to the outside* is:
--   copied   prompt, limits, model, autonomy, task-model flag, agent config
--            (incl. function overrides), active flag, permissions (incl. who
--            it may delegate to), execution rules, teams (main and extra),
--            Canvas position (nudged so it does not sit on the original)
--   not      memories, sessions, tasks, schedules, inbound sources, user
--            assignments, rooms, and delegations *to* the original
CREATE OR REPLACE FUNCTION allgres_public.fn_agent_clone(
  p_token text, p_source uuid, p_name text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE := allgres_private.require_admin(p_token);
  s allgres_private.agents%ROWTYPE;
  p allgres_private.policies%ROWTYPE;
  v_name text;
  v_id uuid;
  r record;
BEGIN
  SELECT * INTO s FROM allgres_private.agents WHERE agent_id = p_source;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;
  IF s.is_system THEN
    RAISE EXCEPTION 'a system agent cannot be copied' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO p FROM allgres_private.policies WHERE agent_id = p_source;
  IF btrim(COALESCE(p_name, '')) <> '' THEN
    v_name := btrim(p_name);
    IF EXISTS (SELECT 1 FROM allgres_private.agents WHERE lower(name) = lower(v_name)) THEN
      RAISE EXCEPTION 'an agent named "%" already exists', v_name USING ERRCODE = 'P0001';
    END IF;
  ELSE
    v_name := allgres_private.canvas_free_agent_name(s.name || '_copy');
  END IF;

  v_id := (allgres_public.fn_create_agent(v_name, p.system_prompt)->>'agent_id')::uuid;
  PERFORM allgres_public.fn_set_policy(
    v_id, NULL, p.max_steps, p.max_retries, p.llm_config, p.max_concurrent_tasks,
    p.max_turn_seconds, p.max_turn_seconds IS NULL, p.max_delegation_depth, p.max_session_tasks);
  -- fn_set_policy leaves llm_config alone when NULL; an empty one must be copied too,
  -- or the default-model trigger's choice would stay on a copy of a model-less agent.
  UPDATE allgres_private.policies SET llm_config = p.llm_config WHERE agent_id = v_id;
  UPDATE allgres_private.agents
     SET autonomy_level = s.autonomy_level, allow_task_model = s.allow_task_model,
         agent_config = s.agent_config, is_active = s.is_active, created_by_user_id = u.user_id, updated_at = now()
   WHERE agent_id = v_id;

  FOR r IN SELECT resource_type, resource_ref FROM allgres_private.permissions
           WHERE agent_id = p_source AND NOT (resource_type = 'agent' AND lower(resource_ref) = lower(v_name))
           ORDER BY resource_type, resource_ref LOOP
    PERFORM allgres_public.fn_grant_permission(v_id, r.resource_type, r.resource_ref);
  END LOOP;
  FOR r IN SELECT action, resource, decision FROM allgres_private.execution_rules WHERE agent_id = p_source LOOP
    PERFORM allgres_public.fn_set_execution_rule(v_id, r.action, r.resource, r.decision);
  END LOOP;

  INSERT INTO allgres_private.agent_group_members (agent_id, group_id)
    SELECT v_id, group_id FROM allgres_private.agent_group_members WHERE agent_id = p_source;
  INSERT INTO allgres_private.agent_group_secondary (agent_id, group_id)
    SELECT v_id, group_id FROM allgres_private.agent_group_secondary WHERE agent_id = p_source;
  INSERT INTO allgres_private.canvas_positions (item_kind, item_id, x, y)
    SELECT 'agent', v_id, x + 40, y + 40 FROM allgres_private.canvas_positions
     WHERE item_kind = 'agent' AND item_id = p_source;

  PERFORM allgres_private.audit('agents.clone', jsonb_build_object(
    'agent_id', v_id, 'name', v_name, 'copied_from', p_source, 'copied_from_name', s.name));
  RETURN jsonb_build_object('ok', true, 'agent_id', v_id, 'name', v_name);
END;
$fn$;
