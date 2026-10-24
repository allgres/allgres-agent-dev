\set ON_ERROR_STOP on
-- Fixture for scripts/run_dump_restore_test.sh (C2). Runs once in the source
-- database of a throwaway cluster. It puts user rows into the user-state
-- tables a logical dump must carry, including the ones only
-- registered for dump in the dump-coverage commit (users, assignments,
-- preferences, chat links, messages, fix proposals, call records, function
-- history, user capabilities, canvas). Needs psql variable :mock_base, the
-- worker's own mock endpoint (http://<ALLGRES_HTTP_ADDR>/mock).

SELECT set_config('allgres_dr.mock_base', :'mock_base', false);

DO $fx$
DECLARE
  v_prov uuid;
  v_chat uuid;
  v_fx uuid;
  v_fn uuid;
  v_plfn uuid;
  v_proc uuid;
  v_user uuid;
  v_group uuid;
  v_cap uuid;
BEGIN
  v_prov := (allgres_public.fn_create_provider('dr_mock', 'openai_compat', current_setting('allgres_dr.mock_base'),
               'dr-fixture-api-key', true)->>'provider_id')::uuid;

  v_chat := (allgres_public.fn_create_agent('dr_chat_agent', 'Answer briefly.')->>'agent_id')::uuid;
  UPDATE allgres_private.policies
  SET llm_config = jsonb_build_object('provider', 'dr_mock', 'model', 'allgres-mock',
                                      'temperature', 0, 'max_tokens', 64),
      updated_at = now()
  WHERE agent_id = v_chat;

  -- Executor-reach fixture, the same shape as tests/fixed_url_procedure_e2e.sql:
  -- a user http_get function bound to a user procedure, granted only the
  -- procedure. The .invalid host makes the worker harvest a DNS failure.
  v_fn := (allgres_public.fn_create_function('dr_fx_get', 'dump/restore worker fixture', 'http_get',
             '{"url":"https://dr-fx.allgres-test.invalid/fixed"}'::jsonb)->>'function_id')::uuid;
  v_proc := (allgres_public.fn_create_procedure('dr-fx-proc', 'Fetch the fixed URL.')->>'procedure_id')::uuid;
  PERFORM allgres_public.fn_bind_procedure_function(v_proc, v_fn);
  v_fx := (allgres_public.fn_create_agent('dr_fx_runner', 'Fetch the fixed URL.')->>'agent_id')::uuid;
  PERFORM allgres_public.fn_grant_permission(v_fx, 'procedure', 'dr-fx-proc');

  -- A plpgsql user function with an edit, so function_history has a row.
  v_plfn := (allgres_public.fn_create_function('dr_user_fn', 'user plpgsql fn', 'plpgsql', '{}'::jsonb,
               'BEGIN RETURN p_args; END;')->>'function_id')::uuid;
  PERFORM allgres_public.fn_update_function(v_plfn, 'user plpgsql fn, edited');
  IF NOT EXISTS (SELECT 1 FROM allgres_private.function_history WHERE function_id = v_plfn) THEN
    INSERT INTO allgres_private.function_history (function_id, generation, description, body, param_schema)
    VALUES (v_plfn, 1, 'user plpgsql fn', 'BEGIN RETURN p_args; END;', '{}'::jsonb);
  END IF;

  -- The account that logs in again after the restore.
  v_user := (allgres_public.fn_create_user('dr_user', 'dr-user-password', 'user')->>'user_id')::uuid;
  INSERT INTO allgres_private.user_agent_assignments (user_id, agent_id) VALUES (v_user, v_chat);
  INSERT INTO allgres_private.user_agent_preferences (user_id, agent_id, llm_config)
  VALUES (v_user, v_chat, '{"temperature": 0}'::jsonb);
  INSERT INTO allgres_private.channel_messages (author_user_id, content)
  VALUES (v_user, 'dump/restore fixture message');

  -- Canvas: a group holding both user agents, its position, a saved template.
  v_group := (allgres_public.fn_canvas_create_group('dr team', 'team', NULL,
                '{"x": 10, "y": 20}'::jsonb, ARRAY[v_chat, v_fx])->>'group_id')::uuid;
  INSERT INTO allgres_private.canvas_positions (item_kind, item_id, x, y)
  VALUES ('agent', v_chat, 30, 40)
  ON CONFLICT (item_kind, item_id) DO UPDATE SET x = EXCLUDED.x, y = EXCLUDED.y;
  PERFORM allgres_public.fn_canvas_save_template('dr template', v_group, v_user);

  PERFORM allgres_public.fn_remember(v_chat, 'The dump/restore fixture likes short answers.');
  PERFORM allgres_public.fn_create_schedule('dr-schedule', v_fx, 'never runs in this test', 86400,
                                            NULL, NULL, now() + interval '30 days');
  PERFORM allgres_public.fn_create_project('dr-project', 'dump/restore fixture', v_chat);

  INSERT INTO allgres_private.fix_proposals (agent_id, fix_kind, target_agent_id, reason)
  VALUES (v_chat, 'deactivate_agent', v_fx, 'dump/restore fixture');

  -- User capability history (the seed capabilities are rebuilt by CREATE
  -- EXTENSION and are not dumped).
  SELECT capability_id INTO STRICT v_cap FROM allgres_private.capability_index WHERE source_id = v_chat;
  INSERT INTO allgres_private.capability_versions (capability_id, version, lifecycle, snapshot, change_note)
  VALUES (v_cap, 1000, 'draft', '{"fixture": true}'::jsonb, 'dump/restore fixture');
  INSERT INTO allgres_private.capability_evaluations (capability_id, status, checks, content_hash)
  VALUES (v_cap, 'passed', '[]'::jsonb, 'dr-fixture');
  INSERT INTO allgres_private.capability_search_events (requester_agent_id, query_text, selected_capability_id, outcome)
  VALUES (v_fx, 'dump/restore fixture', v_cap, 'selected');
END
$fx$;

SELECT 'dump/restore fixture ok' AS result;
