\set ON_ERROR_STOP on

-- Run in postgres with the Rust runtime worker enabled. Every queueing
-- statement commits before polling; no SQL completion is simulated here.
-- http_get rejects private addresses at creation and in GuardedResolver.
-- The RFC 2606 .invalid URL proves worker handoff through a DNS failure
-- without a private mock endpoint or any security exception.
DO $block$
DECLARE
  v_fn uuid;
  v_proc uuid;
  v_agent uuid;
BEGIN
  IF current_database() <> 'postgres' THEN
    RAISE EXCEPTION 'fixed URL e2e requires database postgres (the runtime worker database)';
  END IF;
  SELECT function_id INTO v_fn FROM allgres_private.functions WHERE name = 'e2e_fx_get';
  IF NOT FOUND THEN
    v_fn := (allgres_public.fn_create_function('e2e_fx_get','fixed URL worker fixture','http_get',
      '{"url":"https://e2e-fx.allgres-test.invalid/fixed?x=1"}'::jsonb)->>'function_id')::uuid;
  END IF;
  SELECT procedure_id INTO v_proc FROM allgres_private.procedures WHERE name = 'e2e-fx-proc';
  IF NOT FOUND THEN
    v_proc := (allgres_public.fn_create_procedure('e2e-fx-proc','Fetch the fixed URL.')->>'procedure_id')::uuid;
  END IF;
  PERFORM allgres_public.fn_bind_procedure_function(v_proc,v_fn);
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'e2e_fx_runner';
  IF NOT FOUND THEN
    v_agent := (allgres_public.fn_create_agent('e2e_fx_runner','Fetch the fixed URL.')->>'agent_id')::uuid;
  END IF;
  -- A repeat run has exactly the same permission boundary: only the procedure.
  DELETE FROM allgres_private.permissions WHERE agent_id = v_agent;
  PERFORM allgres_public.fn_grant_permission(v_agent,'procedure','e2e-fx-proc');
  IF (SELECT count(*) FROM allgres_private.permissions WHERE agent_id = v_agent) <> 1 THEN
    RAISE EXCEPTION 'fixed URL runner must hold only its procedure';
  END IF;
END
$block$;

CREATE TEMP TABLE _fixed_url_procedure_e2e(task_id uuid, call_id uuid);
SELECT (allgres_public.fn_create_session(
  (SELECT agent_id FROM allgres_private.agents WHERE name = 'e2e_fx_runner'),
  'fixed URL procedure e2e'
)->>'session_id') AS fixed_url_session_id \gset
INSERT INTO _fixed_url_procedure_e2e(task_id)
SELECT task_id FROM allgres_private.tasks WHERE session_id = :'fixed_url_session_id'::uuid;
SELECT allgres_public.fn_next_step(task_id) FROM _fixed_url_procedure_e2e;
UPDATE _fixed_url_procedure_e2e
SET call_id = (allgres_public.fn_submit_result(task_id, jsonb_build_object(
  'type', 'llm_response', 'content', '{"action":"call_function","function":"e2e_fx_get"}',
  'parsed', jsonb_build_object('action', 'call_function', 'function', 'e2e_fx_get', 'args', '{"url":"https://evil.example/override"}'::jsonb)
))->>'call_id')::uuid;

DO $block$
DECLARE
  v_task uuid;
  v_call uuid;
  v_status text;
  v_proc uuid;
  v_body text;
BEGIN
  SELECT task_id, call_id INTO STRICT v_task, v_call FROM _fixed_url_procedure_e2e;
  IF v_call IS NULL THEN
    RAISE EXCEPTION 'fixed URL procedure e2e did not enqueue a call (task=%)', v_task;
  END IF;
  FOR i IN 1..200 LOOP
    SELECT status, procedure_id, response_body INTO v_status, v_proc, v_body
    FROM allgres_private.outbound_calls WHERE call_id = v_call AND task_id = v_task;
    EXIT WHEN v_status NOT IN ('queued', 'in_flight');
    PERFORM pg_sleep(0.1);
  END LOOP;
  -- fn_complete_outbound records the worker's transport error in response_body
  -- and sets harvested. This test never calls a claim or completion function.
  IF v_status IS DISTINCT FROM 'harvested'
     OR v_proc IS DISTINCT FROM (SELECT procedure_id FROM allgres_private.procedures WHERE name = 'e2e-fx-proc')
     OR v_body IS NULL OR v_body NOT ILIKE '%host not found%'
     OR NOT EXISTS (SELECT 1 FROM allgres_private.outbound_calls
                    WHERE call_id = v_call AND kind = 'function' AND function = 'http_get'
                      AND url = 'https://e2e-fx.allgres-test.invalid/fixed?x=1'
                      AND procedure_function_id = (SELECT function_id FROM allgres_private.functions WHERE name = 'e2e_fx_get')
                      AND NOT allow_private AND response_status = 0)
     OR EXISTS (SELECT 1 FROM allgres_private.function_calls WHERE task_id = v_task) THEN
    RAISE EXCEPTION 'fixed URL procedure e2e was not executed (call=%, status=%, procedure=%, body=%)',
      v_call, v_status, v_proc, v_body;
  END IF;
  IF EXISTS (SELECT 1 FROM allgres_private.execution_logs
             WHERE task_id = v_task AND role = 'error'
               AND content->>'reason' IN ('http_host_not_permitted', 'function_not_permitted', 'procedure_not_permitted')) THEN
    RAISE EXCEPTION 'fixed URL procedure e2e logged a permission failure (task=%)', v_task;
  END IF;
END
$block$;

DROP TABLE _fixed_url_procedure_e2e;

SELECT 'fixed URL procedure e2e ok' AS result;
