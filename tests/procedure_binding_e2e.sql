\set ON_ERROR_STOP on

-- Run with the Rust worker and mock web worker enabled, after
-- capability_search_e2e.sql. Queueing statements commit before polling so
-- the executor can see the call; fn_selftest cannot prove this handoff.
DO $block$
DECLARE
  v_conn uuid;
  v_fn uuid;
  v_proc uuid;
  v_agent uuid;
BEGIN
  SELECT connection_id INTO v_conn FROM allgres_private.api_connections WHERE name = 'e2e_pb_mock';
  IF NOT FOUND THEN
    v_conn := (allgres_public.fn_create_connection(
      'e2e_pb_mock', 'http://127.0.0.1:8088/mock/mcp', 'none', NULL, true)->>'connection_id')::uuid;
  END IF;
  SELECT function_id INTO v_fn FROM allgres_private.functions WHERE name = 'e2e_pb_mcp';
  IF NOT FOUND THEN
    v_fn := (allgres_public.fn_create_function('e2e_pb_mcp', 'procedure binding worker fixture',
      'mcp_call', '{"tool":"e2e_pb_tool"}'::jsonb, NULL, NULL, NULL, v_conn)->>'function_id')::uuid;
  END IF;
  SELECT procedure_id INTO v_proc FROM allgres_private.procedures WHERE name = 'e2e-pb-proc';
  IF NOT FOUND THEN
    v_proc := (allgres_public.fn_create_procedure(
      'e2e-pb-proc', 'Call the bound MCP tool.')->>'procedure_id')::uuid;
  END IF;
  PERFORM allgres_public.fn_bind_procedure_function(v_proc, v_fn);
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'e2e_pb_runner';
  IF NOT FOUND THEN
    v_agent := (allgres_public.fn_create_agent('e2e_pb_runner', 'Call the bound MCP tool.')->>'agent_id')::uuid;
  END IF;
  -- Reproduce legacy state: the public grant API refuses this direct row.
  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  VALUES (v_agent, 'function', 'e2e_pb_mcp') ON CONFLICT DO NOTHING;
  PERFORM allgres_public.fn_grant_permission(v_agent, 'procedure', 'e2e-pb-proc');
END
$block$;

CREATE TEMP TABLE _procedure_binding_e2e(task_id uuid, call_id uuid);
SELECT (allgres_public.fn_create_session(
  (SELECT agent_id FROM allgres_private.agents WHERE name = 'e2e_pb_runner'),
  'procedure binding e2e'
)->>'session_id') AS procedure_binding_session_id \gset
INSERT INTO _procedure_binding_e2e(task_id)
SELECT task_id FROM allgres_private.tasks WHERE session_id = :'procedure_binding_session_id'::uuid;
SELECT allgres_public.fn_next_step(task_id) FROM _procedure_binding_e2e;
UPDATE _procedure_binding_e2e
SET call_id = (allgres_public.fn_submit_result(task_id, jsonb_build_object(
  'type', 'llm_response', 'content', '{"action":"call_function","function":"e2e_pb_mcp"}',
  'parsed', jsonb_build_object('action', 'call_function', 'function', 'e2e_pb_mcp', 'args', '{}'::jsonb)
))->>'call_id')::uuid;

DO $block$
DECLARE
  v_task uuid;
  v_call uuid;
  v_status text;
  v_proc uuid;
  v_body text;
BEGIN
  SELECT task_id, call_id INTO STRICT v_task, v_call FROM _procedure_binding_e2e;
  IF v_call IS NULL THEN
    RAISE EXCEPTION 'procedure binding e2e did not enqueue a call (task=%)', v_task;
  END IF;
  FOR i IN 1..200 LOOP
    SELECT status, procedure_id, response_body INTO v_status, v_proc, v_body
    FROM allgres_private.outbound_calls WHERE call_id = v_call AND task_id = v_task;
    EXIT WHEN v_status NOT IN ('queued', 'in_flight');
    PERFORM pg_sleep(0.1);
  END LOOP;
  -- The mock returns a 404 JSON body on this path. Recording that answer
  -- proves the Rust executor sent the request, even though the tool fails.
  IF v_status IS DISTINCT FROM 'harvested' OR v_proc IS NULL OR v_body IS NULL
     OR v_body::jsonb IS DISTINCT FROM '{"ok":false,"error":"not_found"}'::jsonb THEN
    RAISE EXCEPTION 'procedure binding e2e was not executed (call=%, status=%, procedure=%, body=%)',
      v_call, v_status, v_proc, v_body;
  END IF;
  IF EXISTS (SELECT 1 FROM allgres_private.execution_logs
             WHERE task_id = v_task AND role = 'error'
               AND content->>'reason' IN ('http_host_not_permitted', 'function_not_permitted')) THEN
    RAISE EXCEPTION 'procedure binding e2e logged a permission failure (task=%)', v_task;
  END IF;
END
$block$;

SELECT 'procedure binding e2e ok' AS result;
