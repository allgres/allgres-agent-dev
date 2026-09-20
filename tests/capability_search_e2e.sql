\set ON_ERROR_STOP on

-- Run after tests/e2e_mock.sql, which configures the deterministic mock
-- embedding provider and proves the worker HTTP path. Each queueing step is
-- its own committed statement so the background worker can see it.
SELECT allgres_public.fn_grant_permission(
  (SELECT agent_id FROM allgres_private.agents WHERE name='e2e_search_requester'),
  'function','seoul_weather');
SELECT allgres_public.fn_grant_permission(
  (SELECT agent_id FROM allgres_private.agents WHERE name='e2e_search_requester'),
  'procedure','seoul-weather');
SELECT allgres_private.sync_capability_index();

DO $block$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN (SELECT count(*) FROM allgres_private.capability_index
      WHERE name IN ('seoul_weather','seoul-weather') AND embedding IS NOT NULL)=2;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF (SELECT count(*) FROM allgres_private.capability_index
      WHERE name IN ('seoul_weather','seoul-weather') AND embedding IS NOT NULL)<>2 THEN
    RAISE EXCEPTION 'capability embeddings did not complete';
  END IF;
END
$block$;

CREATE TEMP TABLE _capability_e2e(task_id uuid);
SELECT (allgres_public.fn_create_session(
  (SELECT agent_id FROM allgres_private.agents WHERE name='e2e_search_requester'),
  'capability search e2e'
)->>'session_id') AS capability_session_id \gset
INSERT INTO _capability_e2e
SELECT task_id FROM allgres_private.tasks
WHERE session_id=:'capability_session_id'::uuid;
SELECT allgres_public.fn_next_step(task_id) FROM _capability_e2e;
SELECT allgres_public.fn_submit_result(task_id,jsonb_build_object(
  'type','llm_response',
  'content','{"action":"search_capabilities","query":"seoul weather"}',
  'parsed',jsonb_build_object('action','search_capabilities','query','seoul weather'))
) FROM _capability_e2e;

DO $block$
DECLARE v_task uuid; v_body text;
BEGIN
  SELECT task_id INTO v_task FROM _capability_e2e;
  FOR i IN 1..200 LOOP
    SELECT l.content->>'body' INTO v_body
    FROM allgres_private.execution_logs l
    WHERE l.task_id=v_task AND l.role='function'
    ORDER BY l.created_at DESC LIMIT 1;
    EXIT WHEN v_body IS NOT NULL;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF v_body IS NULL OR v_body NOT LIKE '%seoul_weather%' OR v_body NOT LIKE '%seoul-weather%' THEN
    RAISE EXCEPTION 'permission-filtered capability results missing: %',v_body;
  END IF;
END
$block$;

SELECT 'capability search e2e ok' AS result;
