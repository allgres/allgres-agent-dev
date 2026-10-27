\set ON_ERROR_STOP on

-- Requires the real background worker and the built-in mock decision model
-- (like mcp_e2e.sql): the question goes out through the worker's HTTP pool to
-- /mock/laya/v1/systemone and the reply comes back through
-- fn_complete_decision_ask. The "observe first" gate is a rule of the setting
-- function, so the test sets the point's row directly to test only the path.
DELETE FROM allgres_private.decision_delegation WHERE point_key = 'approval_decision';
DELETE FROM allgres_private.api_connections WHERE name = 'delegation_e2e_laya';

SELECT allgres_public.fn_decision_model_connect('delegation_e2e_laya', 'http://127.0.0.1:8088/mock/laya', NULL, true) AS conn \gset

INSERT INTO allgres_private.decision_delegation (point_key, mode, connection_id, all_agents, min_confidence)
VALUES ('approval_decision', 'delegate', (:'conn'::jsonb->>'connection_id')::uuid, true, 0.8);

DO $$
DECLARE
  v_agent uuid := (SELECT agent_id FROM allgres_private.agents WHERE name = 'delegation_e2e_agent');
  v_task uuid; v_appr uuid; v_sid uuid; r record;
  v_reasons text[] := ARRAY['LAYA_REJECT please', 'LAYA_LOW unsure', 'LAYA_DOWN broken'];
  v_ids uuid[] := ARRAY[]::uuid[];
  i int;
BEGIN
  IF v_agent IS NULL THEN
    v_agent := (allgres_public.fn_create_agent('delegation_e2e_agent', 'asks for approvals')->>'agent_id')::uuid;
  END IF;
  FOR i IN 1..3 LOOP
    v_sid := (allgres_public.fn_create_session(v_agent, 'delegation e2e ' || i)->>'session_id')::uuid;
    SELECT task_id INTO v_task FROM allgres_private.tasks WHERE session_id = v_sid;
    UPDATE allgres_private.tasks SET status = 'waiting_human' WHERE task_id = v_task;
    INSERT INTO allgres_private.human_approvals (task_id, status, payload)
    VALUES (v_task, 'pending', jsonb_build_object('reason', v_reasons[i])) RETURNING approval_id INTO v_appr;
    v_ids := v_ids || v_appr;
  END LOOP;
  COMMIT;
  FOR i IN 1..40 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM allgres_private.decision_asks WHERE source_id = ANY (v_ids) AND status IN ('queued', 'in_flight'));
    PERFORM pg_sleep(0.5);
    COMMIT;
  END LOOP;
  FOR r IN SELECT a.source_id, a.status, a.outcome, a.note FROM allgres_private.decision_asks a WHERE a.source_id = ANY (v_ids) ORDER BY array_position(v_ids, a.source_id) LOOP
    RAISE NOTICE 'ask % -> % / % (%)', array_position(v_ids, r.source_id), r.status, r.outcome, r.note;
  END LOOP;
  -- 1: a sure reject is applied and kept as the model's
  IF NOT EXISTS (SELECT 1 FROM allgres_private.decision_asks WHERE source_id = v_ids[1] AND outcome = 'applied' AND answer = 'reject')
     OR NOT EXISTS (SELECT 1 FROM allgres_private.human_approvals WHERE approval_id = v_ids[1] AND status = 'rejected')
     OR NOT EXISTS (SELECT 1 FROM allgres_private.decision_records WHERE source_id = v_ids[1] AND decided_by = 'laya')
     OR EXISTS (SELECT 1 FROM allgres_private.decision_labels l JOIN allgres_private.decision_records d USING (record_id) WHERE d.source_id = v_ids[1]) THEN
    RAISE EXCEPTION 'delegation e2e: the confident reject was not applied as the model''s decision';
  END IF;
  -- 2: a doubtful answer stays with the person
  IF NOT EXISTS (SELECT 1 FROM allgres_private.decision_asks WHERE source_id = v_ids[2] AND outcome = 'left_to_person' AND low_confidence)
     OR NOT EXISTS (SELECT 1 FROM allgres_private.human_approvals WHERE approval_id = v_ids[2] AND status = 'pending') THEN
    RAISE EXCEPTION 'delegation e2e: a doubtful answer did not stay with the person';
  END IF;
  -- 3: a stopped server stays with the person and nothing is lost
  IF NOT EXISTS (SELECT 1 FROM allgres_private.decision_asks WHERE source_id = v_ids[3] AND outcome = 'left_to_person' AND status = 'failed')
     OR NOT EXISTS (SELECT 1 FROM allgres_private.human_approvals WHERE approval_id = v_ids[3] AND status = 'pending') THEN
    RAISE EXCEPTION 'delegation e2e: a failed ask did not stay with the person';
  END IF;
END $$;

-- Leave nothing waiting for a person behind.
UPDATE allgres_private.human_approvals SET status = 'rejected', decided_at = now()
WHERE status = 'pending' AND task_id IN (SELECT t.task_id FROM allgres_private.tasks t JOIN allgres_private.agents a USING (agent_id) WHERE a.name = 'delegation_e2e_agent');
UPDATE allgres_private.tasks SET status = 'failed', error = 'delegation e2e cleanup'
WHERE status = 'waiting_human' AND agent_id = (SELECT agent_id FROM allgres_private.agents WHERE name = 'delegation_e2e_agent');
DELETE FROM allgres_private.decision_delegation WHERE point_key = 'approval_decision';
SELECT 'delegation e2e ok' AS result;
