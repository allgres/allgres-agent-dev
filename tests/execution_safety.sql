\set ON_ERROR_STOP on

-- Real agent-role execution, not only SECURITY DEFINER guard calls. All
-- fixtures (including generated objects and roles) disappear on rollback.
BEGIN;
DO $test$
DECLARE
  a uuid; f uuid; p uuid; t uuid; c uuid; ap uuid;
  fi text; pi text; ro text; result jsonb; blocked boolean;
BEGIN
  a := (allgres_public.fn_create_agent('execution_safety_fixture')->>'agent_id')::uuid;
  SELECT pg_role INTO ro FROM allgres_private.agents WHERE agent_id = a;
  f := (allgres_public.fn_create_function('execution_safety_fn', 'fixture', 'plpgsql', '{}',
    'BEGIN RETURN jsonb_build_object(''executed'',true); END;')->>'function_id')::uuid;
  SELECT sql_ident INTO fi FROM allgres_private.functions WHERE function_id = f;
  -- Match the worker's outer guard; the e2e suite exercises worker-built DDL.
  EXECUTE format('CREATE FUNCTION allgres_functions.%I(p_args jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER AS %L', fi,
    format('BEGIN PERFORM allgres_private.assert_local_execution(%L); BEGIN RETURN jsonb_build_object(''executed'',true); END; END;', fi));
  UPDATE allgres_private.functions SET build_status = 'built' WHERE function_id = f;
  p := (allgres_public.fn_create_procedure('execution_safety_proc', 'fixture',
    format('BEGIN p_result := allgres_functions.%I(p_args); END;', fi))->>'procedure_id')::uuid;
  SELECT sql_ident INTO pi FROM allgres_private.procedures WHERE procedure_id = p;
  EXECUTE format('CREATE PROCEDURE allgres_functions.%I(p_args jsonb, INOUT p_result jsonb) LANGUAGE plpgsql SECURITY INVOKER AS %L', pi,
    format('BEGIN PERFORM allgres_private.assert_local_execution(%L); BEGIN p_result := allgres_functions.%I(p_args); END; END;', pi, fi));
  UPDATE allgres_private.procedures SET build_status = 'built' WHERE procedure_id = p;
  PERFORM allgres_public.fn_grant_permission(a, 'function', 'execution_safety_fn');
  PERFORM allgres_public.fn_grant_permission(a, 'procedure', 'execution_safety_proc');
  PERFORM allgres_public.fn_bind_procedure_function(p, f);

  PERFORM allgres_public.fn_set_execution_rule(a, 'call_function', 'execution_safety_fn', 'deny');
  t := (allgres_public.fn_create_session(a, 'deny dependency')->>'task_id')::uuid;
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = t;
  INSERT INTO allgres_private.procedure_calls(task_id, procedure_id, agent_id, args)
    VALUES(t, p, a, '{}') RETURNING call_id INTO c;
  IF allgres_private.guard_queued_call('procedure_calls', c) THEN
    RAISE EXCEPTION 'denied dependency passed procedure claim';
  END IF;

  -- Removing a binding cannot bypass runtime checks. This also covers a
  -- function called dynamically or from another function/execute_sql.
  DELETE FROM allgres_private.procedure_function_bindings WHERE procedure_id = p;
  EXECUTE format('SET LOCAL ROLE %I', ro);
  blocked := false;
  BEGIN
    EXECUTE format('CALL allgres_functions.%I(''{}''::jsonb,''{}''::jsonb)', pi) INTO result;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'execution denied:%' THEN RAISE; END IF;
    blocked := true;
  END;
  RESET ROLE;
  IF NOT blocked THEN RAISE EXCEPTION 'nested denied function executed'; END IF;

  PERFORM allgres_public.fn_set_execution_rule(a, 'call_function', 'execution_safety_fn', 'approve');
  EXECUTE format('SET LOCAL ROLE %I', ro);
  blocked := false;
  BEGIN
    -- A caller-controlled setting must not mint execution authority.
    PERFORM set_config('allgres.approval_id', gen_random_uuid()::text, true);
    EXECUTE format('CALL allgres_functions.%I(''{}''::jsonb,''{}''::jsonb)', pi) INTO result;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'execution requires approval:%' THEN RAISE; END IF;
    blocked := true;
  END;
  RESET ROLE;
  IF NOT blocked THEN RAISE EXCEPTION 'unapproved nested function executed'; END IF;
  IF has_function_privilege(ro, 'allgres_private.begin_local_execution(text,uuid)', 'EXECUTE')
     OR has_table_privilege(ro, 'allgres_private.local_execution_context', 'INSERT') THEN
    RAISE EXCEPTION 'agent can forge protected execution context';
  END IF;

  PERFORM allgres_public.fn_bind_procedure_function(p, f);
  t := (allgres_public.fn_create_session(a, 'approve dependency')->>'task_id')::uuid;
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = t;
  INSERT INTO allgres_private.procedure_calls(task_id, procedure_id, agent_id, args)
    VALUES(t, p, a, '{}') RETURNING call_id INTO c;
  IF allgres_private.guard_queued_call('procedure_calls', c) THEN
    RAISE EXCEPTION 'dependency approval did not pause root';
  END IF;
  SELECT approval_id INTO ap FROM allgres_private.human_approvals WHERE task_id = t AND status = 'pending';
  PERFORM allgres_public.fn_decide_approval(ap, true, 'approved');
  UPDATE allgres_private.functions SET generation = generation + 1,
    body = 'BEGIN RETURN jsonb_build_object(''changed'',true); END;' WHERE function_id = f;
  IF allgres_private.guard_queued_call('procedure_calls', c) THEN
    RAISE EXCEPTION 'changed dependency reused old approval';
  END IF;
  SELECT approval_id INTO ap FROM allgres_private.human_approvals WHERE task_id = t AND status = 'pending';
  -- now() ties in this rollback transaction; model separate decision turns.
  UPDATE allgres_private.human_approvals SET created_at = clock_timestamp() WHERE approval_id = ap;
  PERFORM allgres_public.fn_decide_approval(ap, true, 'approved changed definition');
  IF NOT allgres_private.guard_queued_call('procedure_calls', c) THEN
    RAISE EXCEPTION 'unchanged approved procedure stayed blocked';
  END IF;
  UPDATE allgres_private.procedure_calls SET status = 'in_flight' WHERE call_id = c;
  PERFORM allgres_private.begin_local_execution('procedure_calls', c);
  EXECUTE format('SET LOCAL ROLE %I', ro);
  EXECUTE format('CALL allgres_functions.%I(''{}''::jsonb,''{}''::jsonb)', pi) INTO result;
  RESET ROLE;
  IF result IS DISTINCT FROM '{"executed":true}'::jsonb THEN RAISE EXCEPTION 'approved nested call failed'; END IF;

  -- Changing a binding after claim must also fail before entering the body.
  DELETE FROM allgres_private.procedure_function_bindings WHERE procedure_id = p;
  EXECUTE format('SET LOCAL ROLE %I', ro);
  blocked := false;
  BEGIN
    EXECUTE format('CALL allgres_functions.%I(''{}''::jsonb,''{}''::jsonb)', pi) INTO result;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'execution approval scope changed%' THEN RAISE; END IF;
    blocked := true;
  END;
  RESET ROLE;
  IF NOT blocked THEN RAISE EXCEPTION 'changed binding reused runtime approval'; END IF;
  RAISE NOTICE 'execution safety: claim denial, nested denial/approval, context isolation, stale dependency/binding, approved execution passed';
END;
$test$;
ROLLBACK;
