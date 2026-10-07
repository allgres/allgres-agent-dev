\set ON_ERROR_STOP on

-- Requires the real background worker (like e2e_mock.sql). The companion
-- execution_safety.sql covers rollback-only negative cases under agent roles.
DELETE FROM allgres_private.procedures WHERE name = 'execution_safety_worker_proc';
DELETE FROM allgres_private.functions WHERE name LIKE 'execution_safety_worker_fn%';

DO $setup$
DECLARE a uuid; f uuid; p uuid; fi text; source text; i int;
BEGIN
  SELECT agent_id INTO a FROM allgres_private.agents WHERE name = 'execution_safety_worker';
  IF a IS NULL THEN a := (allgres_public.fn_create_agent('execution_safety_worker')->>'agent_id')::uuid; END IF;
  FOR i IN 1..4 LOOP
    source := CASE i
      WHEN 1 THEN $body$BEGIN
        BEGIN
          PERFORM set_config('role', 'none', true);
          RETURN jsonb_build_object('role_escape', true);
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
        RETURN jsonb_build_object('executed',true);
      END$body$
      WHEN 2 THEN E'BEGIN RETURN p_args; END; -- trailing comment'
      WHEN 3 THEN E'DECLARE x jsonb := p_args; BEGIN RETURN x; END /* trailing comment */'
      -- Valid only if the builder forgets to validate the standalone body:
      -- this would catch the guard's exception in the generated outer block.
      WHEN 4 THEN 'BEGIN RETURN p_args; END; EXCEPTION WHEN OTHERS THEN RETURN p_args;'
    END;
    f := (allgres_public.fn_create_function('execution_safety_worker_fn' || i,
      'worker guard fixture', 'plpgsql', '{}', source)->>'function_id')::uuid;
    IF i = 1 THEN
      SELECT sql_ident INTO fi FROM allgres_private.functions WHERE function_id = f;
      p := (allgres_public.fn_create_procedure('execution_safety_worker_proc', 'worker fixture',
        format('BEGIN p_result := allgres_functions.%I(p_args); END', fi))->>'procedure_id')::uuid;
      PERFORM allgres_public.fn_bind_procedure_function(p, f);
    END IF;
  END LOOP;
  PERFORM allgres_public.fn_grant_permission(a, 'procedure', 'execution_safety_worker_proc');
  PERFORM allgres_public.fn_set_execution_rule(a, 'call_function', 'execution_safety_worker_fn1', 'approve');
END;
$setup$;

DO $wait$
BEGIN
  FOR i IN 1..30 LOOP
    IF (SELECT count(*) = 3 FROM allgres_private.functions
        WHERE name IN ('execution_safety_worker_fn1','execution_safety_worker_fn2','execution_safety_worker_fn3') AND build_status = 'built')
      AND EXISTS (SELECT 1 FROM allgres_private.functions WHERE name = 'execution_safety_worker_fn4' AND build_status = 'failed')
      AND EXISTS (SELECT 1 FROM allgres_private.procedures WHERE name = 'execution_safety_worker_proc' AND build_status = 'built') THEN RETURN; END IF;
    PERFORM pg_sleep(1);
  END LOOP;
  RAISE EXCEPTION 'guarded worker builds did not reach expected built/failed states';
END;
$wait$;

DO $queue$
DECLARE a uuid; t uuid; p uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM allgres_private.functions f JOIN pg_proc r ON r.proname = f.sql_ident
    WHERE f.name LIKE 'execution_safety_worker_fn%' AND f.build_status = 'built'
      AND r.prosrc NOT LIKE '%PERFORM allgres_private.assert_local_execution(%') THEN
    RAISE EXCEPTION 'worker emitted an unguarded function';
  END IF;
  IF EXISTS (SELECT 1 FROM allgres_private.functions f JOIN pg_proc r ON r.proname = f.sql_ident
    WHERE f.name = 'execution_safety_worker_fn4') THEN
    RAISE EXCEPTION 'failed build left an executable object';
  END IF;
  SELECT agent_id INTO a FROM allgres_private.agents WHERE name = 'execution_safety_worker';
  SELECT procedure_id INTO p FROM allgres_private.procedures WHERE name = 'execution_safety_worker_proc';
  t := (allgres_public.fn_create_session(a, 'execution safety worker approval')->>'task_id')::uuid;
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = t;
  INSERT INTO allgres_private.procedure_calls(task_id, procedure_id, agent_id, args) VALUES(t, p, a, '{}');
END;
$queue$;

DO $approve$
DECLARE ap uuid;
BEGIN
  FOR i IN 1..30 LOOP
    SELECT h.approval_id INTO ap FROM allgres_private.human_approvals h
      JOIN allgres_private.tasks t USING(task_id) JOIN allgres_private.agents a USING(agent_id)
      WHERE a.name = 'execution_safety_worker' AND h.status = 'pending'
        AND h.payload->>'queue' = 'procedure_calls' ORDER BY h.created_at DESC LIMIT 1;
    IF ap IS NOT NULL THEN
      PERFORM allgres_public.fn_decide_approval(ap, true, 'approved worker fixture');
      RETURN;
    END IF;
    PERFORM pg_sleep(1);
  END LOOP;
  RAISE EXCEPTION 'worker did not request approval for bound function';
END;
$approve$;

DO $result$
DECLARE c allgres_private.procedure_calls%ROWTYPE;
BEGIN
  FOR i IN 1..30 LOOP
    SELECT pc.* INTO c FROM allgres_private.procedure_calls pc JOIN allgres_private.procedures p USING(procedure_id)
      WHERE p.name = 'execution_safety_worker_proc' ORDER BY pc.created_at DESC LIMIT 1;
    IF c.status = 'harvested' THEN
      IF NOT EXISTS (SELECT 1 FROM allgres_private.execution_logs WHERE task_id = c.task_id
        AND role = 'procedure' AND content->'result' = '{"executed":true}'::jsonb) THEN
        RAISE EXCEPTION 'approved worker call failed: %', to_jsonb(c);
      END IF;
      RAISE NOTICE 'execution safety worker: guarded builds, invalid-body rollback, approval pause/resume and nested execution passed';
      RETURN;
    END IF;
    PERFORM pg_sleep(1);
  END LOOP;
  RAISE EXCEPTION 'approved procedure did not complete';
END;
$result$;
