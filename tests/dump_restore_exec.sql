\set ON_ERROR_STOP on
-- Executor reach for scripts/run_dump_restore_test.sh: run in the database
-- the runtime worker is attached to (before the dump, and again on the
-- restored database). The agent asks for dr_fx_get through its procedure;
-- the worker must claim the call and harvest the DNS failure. Nothing here
-- claims or completes the call itself.
CREATE TEMP TABLE _dr_exec(task_id uuid, call_id uuid);
SELECT (allgres_public.fn_create_session(
  (SELECT agent_id FROM allgres_private.agents WHERE name = 'dr_fx_runner'),
  'dump/restore executor reach'
)->>'session_id') AS dr_session_id \gset
INSERT INTO _dr_exec(task_id)
SELECT task_id FROM allgres_private.tasks WHERE session_id = :'dr_session_id'::uuid;
SELECT allgres_public.fn_next_step(task_id) IS NOT NULL AS next_step FROM _dr_exec;
UPDATE _dr_exec
SET call_id = (allgres_public.fn_submit_result(task_id, jsonb_build_object(
  'type', 'llm_response', 'content', '{"action":"call_function","function":"dr_fx_get"}',
  'parsed', jsonb_build_object('action', 'call_function', 'function', 'dr_fx_get', 'args', '{}'::jsonb)
))->>'call_id')::uuid;

DO $block$
DECLARE
  v_task uuid;
  v_call uuid;
  v_status text;
  v_body text;
BEGIN
  SELECT task_id, call_id INTO STRICT v_task, v_call FROM _dr_exec;
  IF v_call IS NULL THEN
    RAISE EXCEPTION 'dump/restore exec: no call was queued (task=%)', v_task;
  END IF;
  FOR i IN 1..300 LOOP
    SELECT status, response_body INTO v_status, v_body
    FROM allgres_private.outbound_calls WHERE call_id = v_call;
    EXIT WHEN v_status NOT IN ('queued', 'in_flight');
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF v_status IS DISTINCT FROM 'harvested'
     OR v_body IS NULL OR v_body NOT ILIKE '%host not found%'
     OR NOT EXISTS (SELECT 1 FROM allgres_private.outbound_calls
                    WHERE call_id = v_call AND kind = 'function' AND function = 'http_get'
                      AND url = 'https://dr-fx.allgres-test.invalid/fixed'
                      AND procedure_id = (SELECT procedure_id FROM allgres_private.procedures WHERE name = 'dr-fx-proc')) THEN
    RAISE EXCEPTION 'dump/restore exec: worker did not harvest the call (call=%, status=%, body=%)',
      v_call, v_status, v_body;
  END IF;
  RAISE NOTICE 'dump/restore exec: call % harvested by the worker in database %', v_call, current_database();
END
$block$;

DROP TABLE _dr_exec;
SELECT 'dump/restore executor reach ok' AS result;
