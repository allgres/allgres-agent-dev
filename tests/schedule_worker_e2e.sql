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
--      fires once (one session), and next_run_at becomes now() + 1 hour.
--   2. short interval: a 1-second schedule with max_runs 2 fires twice, on
--      its own, then deactivates.
--   3. no duplicate session for the same schedule firing under forced
--      contention: while transaction A (running the worker's
--      fn_run_schedules as allgres_worker) provably holds the fired row's
--      lock, transaction B (and the worker itself) create no second session.
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
WHERE name IN ('e2e_sched_catchup', 'e2e_sched_short', 'e2e_sched_race') OR name LIKE 'e2e\_sched\_race\_lost\_%';

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

-- Part 3: forced contention between two worker-path transactions.
-- Connections A and B (dblink) each assume allgres_worker and call
-- fn_run_schedules exactly like the worker tick. The test only proceeds
-- once A has fired the due schedule and a NOWAIT probe from a third
-- connection proves A holds that schedule row's lock. Then B runs while A
-- still holds it (B must neither fire nor wait), A commits, and B runs
-- again. The real worker ticks throughout as another contender. If the
-- worker fires a fresh due schedule before A can (A fired 0), that attempt
-- proves nothing and is retried with a new schedule; after 5 such attempts
-- the test FAILS. There is no path that passes without contention.
-- Check: no duplicate session is created for the same schedule firing.
SELECT NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') AS created_dblink \gset
CREATE EXTENSION IF NOT EXISTS dblink;

DO $block$
DECLARE
  v_conn text := format('dbname=%s port=%s host=%s', current_database(),
                        current_setting('port'), split_part(current_setting('unix_socket_directories'), ',', 1));
  v_agent uuid := (SELECT agent_id FROM allgres_private.agents WHERE name = 'e2e_sched_runner');
  v_sched uuid;
  r_a text;
  r_b1 text;
  r_b2 text;
  v_probe_state text;
  v_locked_by_a boolean := false;
  v_attempt int := 0;
  s allgres_private.schedules%ROWTYPE;
BEGIN
  PERFORM dblink_connect('sched_a', v_conn);
  PERFORM dblink_connect('sched_b', v_conn);
  PERFORM dblink_connect('sched_c', v_conn);  -- autocommit helper and lock probe

  WHILE NOT v_locked_by_a LOOP
    v_attempt := v_attempt + 1;
    IF v_attempt > 5 THEN
      RAISE EXCEPTION 'e2e_sched_race: could not force contention: the worker fired every due race schedule before connection A (5 attempts)';
    END IF;
    -- A lost attempt's schedule is kept out of the way, not deleted, so its
    -- worker-fired session stays traceable; cleaned up at the end.
    PERFORM dblink_exec('sched_c', format(
      'UPDATE allgres_private.schedules SET name = %L, is_active = false WHERE name = ''e2e_sched_race''',
      'e2e_sched_race_lost_' || v_attempt));
    SELECT x::uuid INTO v_sched FROM dblink('sched_c', format(
      'SELECT allgres_public.fn_create_schedule(''e2e_sched_race'', %L::uuid, ''Return the Allgres MVP mock answer.'', 3600, p_start_at => now() + interval ''2 seconds'')->>''schedule_id''',
      v_agent)) AS t(x text);
    -- Start A only once the schedule is due: fn_run_schedules compares
    -- against now(), the transaction start time.
    PERFORM pg_sleep(0.05 + GREATEST(0, extract(epoch FROM
      (SELECT next_run_at FROM allgres_private.schedules WHERE schedule_id = v_sched) - clock_timestamp())));
    PERFORM dblink_exec('sched_a', 'BEGIN');
    PERFORM * FROM dblink('sched_a', 'SELECT allgres.assume_worker_role()::text') AS t(x text);
    SELECT x INTO r_a FROM dblink('sched_a', 'SELECT allgres_public.fn_run_schedules()::text') AS t(x text);
    IF (r_a::jsonb->>'fired')::int = 0 THEN
      PERFORM dblink_exec('sched_a', 'ROLLBACK');
      RAISE NOTICE 'e2e_sched_race: attempt % lost to the worker (A=%), retrying', v_attempt, r_a;
      CONTINUE;
    END IF;
    -- Prove A holds the row lock: a NOWAIT lock attempt must fail with 55P03.
    v_probe_state := NULL;
    BEGIN
      PERFORM * FROM dblink('sched_c', format(
        'SELECT schedule_id::text FROM allgres_private.schedules WHERE schedule_id = %L FOR UPDATE NOWAIT', v_sched)) AS t(x text);
      v_probe_state := 'acquired';
    EXCEPTION WHEN others THEN
      v_probe_state := SQLSTATE;
    END;
    IF v_probe_state IS DISTINCT FROM '55P03' THEN
      RAISE EXCEPTION 'e2e_sched_race: A fired (A=%) but the NOWAIT probe did not find the schedule row locked (probe=%)',
        r_a, v_probe_state;
    END IF;
    v_locked_by_a := true;
  END LOOP;

  PERFORM dblink_exec('sched_b', 'BEGIN');
  PERFORM * FROM dblink('sched_b', 'SELECT allgres.assume_worker_role()::text') AS t(x text);
  -- A worker tick must never wait on another tick's schedule row: B fails
  -- (instead of the test hanging) if it ever blocks on A's lock.
  PERFORM dblink_exec('sched_b', 'SET LOCAL lock_timeout = ''3s''');
  BEGIN
    SELECT x INTO r_b1 FROM dblink('sched_b', 'SELECT allgres_public.fn_run_schedules()::text') AS t(x text);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'e2e_sched_race: a second tick blocked on or failed against the first tick''s locked schedule row: %', SQLERRM;
  END;
  PERFORM pg_sleep(5);  -- the worker ticks against A's lock too (idle backoff <= 4 s)
  PERFORM dblink_exec('sched_a', 'COMMIT');
  SELECT x INTO r_b2 FROM dblink('sched_b', 'SELECT allgres_public.fn_run_schedules()::text') AS t(x text);
  PERFORM dblink_exec('sched_b', 'COMMIT');
  PERFORM dblink_disconnect('sched_a');
  PERFORM dblink_disconnect('sched_b');
  PERFORM dblink_disconnect('sched_c');
  PERFORM pg_sleep(5);
  SELECT * INTO s FROM allgres_private.schedules WHERE schedule_id = v_sched;
  IF s.run_count <> 1
     OR (SELECT count(*) FROM allgres_private.sessions WHERE schedule_id = s.schedule_id) <> 1
     OR (r_b1::jsonb->>'fired')::int <> 0 OR (r_b2::jsonb->>'fired')::int <> 0 THEN
    RAISE EXCEPTION 'e2e_sched_race: concurrent ticks fired the schedule % time(s) (sessions=%, A=%, B while A held=%, B after A=%)',
      s.run_count, (SELECT count(*) FROM allgres_private.sessions WHERE schedule_id = s.schedule_id), r_a, r_b1, r_b2;
  END IF;
  RAISE NOTICE 'e2e_sched_race: contention forced on attempt % (NOWAIT probe=55P03); one firing, one session (A=%, B while A held=%, B after A committed=%)',
    v_attempt, r_a, r_b1, r_b2;
END
$block$;
SELECT pg_temp.assert_schedule_sessions_reached_executor('e2e_sched_race', 1);

SELECT CASE WHEN :'created_dblink'::boolean THEN 'DROP EXTENSION dblink' ELSE 'SELECT 1' END AS drop_dblink \gset
:drop_dblink;

DELETE FROM allgres_private.schedules
WHERE name IN ('e2e_sched_catchup', 'e2e_sched_short', 'e2e_sched_race') OR name LIKE 'e2e\_sched\_race\_lost\_%';

SELECT 'schedule worker e2e ok' AS result;
