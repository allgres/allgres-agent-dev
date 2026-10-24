\set ON_ERROR_STOP on

-- Schedules fire from the runtime background worker alone (defect D5: the
-- worker tick never called fn_run_schedules, so nothing fired unless someone
-- called fn_pump or "run now"). Nothing in parts 1 and 2 calls
-- fn_run_schedules, fn_run_schedule_now or fn_pump: run_count can only move
-- because the worker ticked. Each fired session must reach the executor: its
-- LLM call is harvested via fn_complete_outbound (the mock model's real HTTP
-- response) and the session completes with the mock's answer.
--
--   1. catch-up: a schedule last due 10 days ago (240 missed hourly runs)
--      fires exactly once, and next_run_at becomes now() + 1 hour.
--   2. short interval: a 1-second schedule with max_runs 2 fires twice, on
--      its own, then deactivates.
--   3. exactly once under concurrency: two transactions running the
--      worker's fn_run_schedules as allgres_worker at the same time (plus the
--      worker itself) fire one due schedule once.
--
-- Needs the worker database (postgres) and dblink for part 3. Rerunnable;
-- deletes its schedules at the end, tests/cleanup.sql retires the agent.

DO $block$
BEGIN
  IF current_database() <> 'postgres' THEN
    RAISE EXCEPTION 'schedule_worker_e2e requires database postgres (the runtime worker database)';
  END IF;
END
$block$;

INSERT INTO allgres_private.llm_providers (name, kind, base_url, is_enabled, allow_private_network)
VALUES ('allgres_mock', 'openai_compat', 'http://127.0.0.1:8088/mock', true, true)
ON CONFLICT (name) DO UPDATE
SET base_url = EXCLUDED.base_url, kind = EXCLUDED.kind, is_enabled = true, allow_private_network = true;

DO $block$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'e2e_sched_runner') THEN
    PERFORM allgres_public.fn_create_agent('e2e_sched_runner', 'Answer briefly.');
  END IF;
END
$block$;

UPDATE allgres_private.policies
SET llm_config = jsonb_build_object('provider', 'allgres_mock', 'model', 'allgres-mock',
                                    'temperature', 0, 'max_tokens', 128),
    updated_at = now()
WHERE agent_id = (SELECT agent_id FROM allgres_private.agents WHERE name = 'e2e_sched_runner');

DELETE FROM allgres_private.schedules
WHERE name IN ('e2e_sched_catchup', 'e2e_sched_short', 'e2e_sched_race');

-- Asserts every session schedule p_name fired completed with the mock answer
-- after a harvested LLM call (waits up to ~20 s for the worker).
CREATE FUNCTION pg_temp.assert_schedule_sessions_reached_executor(p_name text, p_expected int)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_sched uuid;
  v_open int;
  v_bad text;
BEGIN
  SELECT schedule_id INTO STRICT v_sched FROM allgres_private.schedules WHERE name = p_name;
  IF (SELECT count(*) FROM allgres_private.sessions WHERE schedule_id = v_sched) <> p_expected THEN
    RAISE EXCEPTION '%: expected % fired session(s), found %', p_name, p_expected,
      (SELECT count(*) FROM allgres_private.sessions WHERE schedule_id = v_sched);
  END IF;
  FOR i IN 1..200 LOOP
    SELECT count(*) INTO v_open FROM allgres_private.sessions
    WHERE schedule_id = v_sched AND status NOT IN ('completed', 'failed');
    EXIT WHEN v_open = 0;
    PERFORM pg_sleep(0.1);
  END LOOP;
  SELECT string_agg(format('%s status=%s answer=%s', s.session_id, s.status, s.final_answer), '; ')
  INTO v_bad
  FROM allgres_private.sessions s
  WHERE s.schedule_id = v_sched
    AND (s.status <> 'completed' OR s.final_answer IS DISTINCT FROM 'Allgres mock runtime OK'
         OR NOT EXISTS (SELECT 1 FROM allgres_private.outbound_calls o
                        JOIN allgres_private.tasks t USING (task_id)
                        WHERE t.session_id = s.session_id AND o.kind = 'llm'
                          AND o.status = 'harvested' AND o.response_status = 200));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '%: fired session did not reach the executor: %', p_name, v_bad;
  END IF;
END
$fn$;

-- Part 1: catch-up. Committed, then left to the worker.
SELECT allgres_public.fn_create_schedule(
  'e2e_sched_catchup',
  (SELECT agent_id FROM allgres_private.agents WHERE name = 'e2e_sched_runner'),
  'Return the Allgres MVP mock answer.', 3600,
  p_start_at => now() - interval '10 days') IS NOT NULL AS created;

DO $block$
DECLARE
  s allgres_private.schedules%ROWTYPE;
BEGIN
  FOR i IN 1..200 LOOP
    SELECT * INTO s FROM allgres_private.schedules WHERE name = 'e2e_sched_catchup';
    EXIT WHEN s.run_count > 0;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF s.run_count = 0 THEN
    RAISE EXCEPTION 'e2e_sched_catchup: the runtime worker did not fire a due schedule within 20 s (run_count=0)';
  END IF;
  -- Give the worker several more ticks (idle backoff is at most 4 s): a
  -- burst of missed runs would show up here.
  PERFORM pg_sleep(5);
  SELECT * INTO s FROM allgres_private.schedules WHERE name = 'e2e_sched_catchup';
  IF s.run_count <> 1 OR NOT s.is_active
     OR s.next_run_at < s.last_run_at + interval '3599 seconds'
     OR s.next_run_at > s.last_run_at + interval '3601 seconds'
     OR s.last_session_id IS NULL THEN
    RAISE EXCEPTION 'e2e_sched_catchup: catch-up must fire once and reschedule at now()+interval (run_count=%, last_run_at=%, next_run_at=%)',
      s.run_count, s.last_run_at, s.next_run_at;
  END IF;
END
$block$;
SELECT pg_temp.assert_schedule_sessions_reached_executor('e2e_sched_catchup', 1);

-- Part 2: short interval, fired repeatedly by the worker alone.
SELECT allgres_public.fn_create_schedule(
  'e2e_sched_short',
  (SELECT agent_id FROM allgres_private.agents WHERE name = 'e2e_sched_runner'),
  'Return the Allgres MVP mock answer.', 1, p_max_runs => 2) IS NOT NULL AS created;

DO $block$
DECLARE
  s allgres_private.schedules%ROWTYPE;
BEGIN
  FOR i IN 1..300 LOOP
    SELECT * INTO s FROM allgres_private.schedules WHERE name = 'e2e_sched_short';
    EXIT WHEN s.run_count >= 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
  PERFORM pg_sleep(2);
  SELECT * INTO s FROM allgres_private.schedules WHERE name = 'e2e_sched_short';
  IF s.run_count <> 2 OR s.is_active THEN
    RAISE EXCEPTION 'e2e_sched_short: expected the worker to fire it twice then deactivate (run_count=%, is_active=%)',
      s.run_count, s.is_active;
  END IF;
END
$block$;
SELECT pg_temp.assert_schedule_sessions_reached_executor('e2e_sched_short', 2);

-- Part 3: two concurrent worker-path transactions. Connections A and B
-- (dblink) each assume allgres_worker and call fn_run_schedules exactly like
-- the worker tick. A fires the due schedule and keeps its transaction open;
-- B runs while A still holds the row; then A commits and B runs again. The
-- real worker ticks throughout as a third contender. Whoever wins, the
-- schedule must fire once.
SELECT NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') AS created_dblink \gset
CREATE EXTENSION IF NOT EXISTS dblink;

SELECT allgres_public.fn_create_schedule(
  'e2e_sched_race',
  (SELECT agent_id FROM allgres_private.agents WHERE name = 'e2e_sched_runner'),
  'Return the Allgres MVP mock answer.', 3600,
  p_start_at => now() + interval '2 seconds') IS NOT NULL AS created;

DO $block$
DECLARE
  v_conn text := format('dbname=%s port=%s host=%s', current_database(),
                        current_setting('port'), split_part(current_setting('unix_socket_directories'), ',', 1));
  r_a text;
  r_b1 text;
  r_b2 text;
  v_locked_by_a boolean;
  s allgres_private.schedules%ROWTYPE;
BEGIN
  PERFORM dblink_connect('sched_a', v_conn);
  PERFORM dblink_connect('sched_b', v_conn);
  -- Start both transactions only once the schedule is due: fn_run_schedules
  -- compares against now(), the transaction start time.
  PERFORM pg_sleep(0.05 + GREATEST(0, extract(epoch FROM
    (SELECT next_run_at FROM allgres_private.schedules WHERE name = 'e2e_sched_race') - clock_timestamp())));
  PERFORM dblink_exec('sched_a', 'BEGIN');
  PERFORM dblink_exec('sched_b', 'BEGIN');
  PERFORM * FROM dblink('sched_a', 'SELECT allgres.assume_worker_role()::text') AS t(x text);
  PERFORM * FROM dblink('sched_b', 'SELECT allgres.assume_worker_role()::text') AS t(x text);
  -- A worker tick must never wait on another tick's schedule row: B fails
  -- (instead of the test hanging) if it ever blocks on A's lock.
  PERFORM dblink_exec('sched_b', 'SET LOCAL lock_timeout = ''3s''');
  SELECT x INTO r_a FROM dblink('sched_a', 'SELECT allgres_public.fn_run_schedules()::text') AS t(x text);
  -- A holds the row now unless the worker got there first.
  v_locked_by_a := (r_a::jsonb->>'fired')::int > 0;
  BEGIN
    SELECT x INTO r_b1 FROM dblink('sched_b', 'SELECT allgres_public.fn_run_schedules()::text') AS t(x text);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'e2e_sched_race: a second tick blocked on or failed against the first tick''s schedule row: %', SQLERRM;
  END;
  PERFORM pg_sleep(5);  -- the worker ticks against A's lock too (idle backoff <= 4 s)
  PERFORM dblink_exec('sched_a', 'COMMIT');
  SELECT x INTO r_b2 FROM dblink('sched_b', 'SELECT allgres_public.fn_run_schedules()::text') AS t(x text);
  PERFORM dblink_exec('sched_b', 'COMMIT');
  PERFORM dblink_disconnect('sched_a');
  PERFORM dblink_disconnect('sched_b');
  PERFORM pg_sleep(5);
  SELECT * INTO s FROM allgres_private.schedules WHERE name = 'e2e_sched_race';
  IF s.run_count <> 1
     OR (SELECT count(*) FROM allgres_private.sessions WHERE schedule_id = s.schedule_id) <> 1
     OR (v_locked_by_a AND ((r_b1::jsonb->>'fired')::int <> 0 OR (r_b2::jsonb->>'fired')::int <> 0)) THEN
    RAISE EXCEPTION 'e2e_sched_race: concurrent ticks fired the schedule % time(s) (sessions=%, A=%, B while A held=%, B after A=%)',
      s.run_count, (SELECT count(*) FROM allgres_private.sessions WHERE schedule_id = s.schedule_id), r_a, r_b1, r_b2;
  END IF;
  RAISE NOTICE 'e2e_sched_race: fired once (A=%, B while A held=%, B after A committed=%, fired by %)',
    r_a, r_b1, r_b2, CASE WHEN v_locked_by_a THEN 'A' ELSE 'the worker' END;
END
$block$;
SELECT pg_temp.assert_schedule_sessions_reached_executor('e2e_sched_race', 1);

SELECT CASE WHEN :'created_dblink'::boolean THEN 'DROP EXTENSION dblink' ELSE 'SELECT 1' END AS drop_dblink \gset
:drop_dblink;

DELETE FROM allgres_private.schedules
WHERE name IN ('e2e_sched_catchup', 'e2e_sched_short', 'e2e_sched_race');

SELECT 'schedule worker e2e ok' AS result;
