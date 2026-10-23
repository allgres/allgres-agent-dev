\set ON_ERROR_STOP on

-- An install created before Function names were reserved can already have a
-- row named like a builtin. This build's trigger refuses writing one, so the
-- legacy row is inserted with triggers skipped (session_replication_role =
-- replica, superuser only) inside one transaction that is rolled back at the
-- end: nothing here is left behind. Kept out of fn_selftest so the selftest
-- never needs ALTER TABLE or an exclusive lock on allgres_private.functions.
BEGIN;

SET LOCAL session_replication_role = replica;
INSERT INTO allgres_private.functions(name, description, handler, body, build_status)
VALUES ('http_get', 'legacy builtin collision', 'plpgsql', 'BEGIN RETURN p_args; END;', 'built');
SET LOCAL session_replication_role = origin;

DO $block$
DECLARE
  v_fn uuid;
  v_ag uuid;
  v_sid uuid;
  v_tid uuid;
  v_call uuid;
  v_tok text;
  r jsonb;
BEGIN
  SELECT function_id INTO STRICT v_fn FROM allgres_private.functions WHERE name = 'http_get';
  -- The trigger is back on: unrelated updates of the legacy row still work.
  UPDATE allgres_private.functions SET description = 'legacy unrelated update', is_active = false WHERE function_id = v_fn;
  UPDATE allgres_private.functions SET is_active = true, build_status = 'built' WHERE function_id = v_fn;

  v_ag := (allgres_public.fn_create_agent('legacy_reserved_runner', 'HTTP')->>'agent_id')::uuid;
  PERFORM allgres_public.fn_grant_permission(v_ag, 'function', 'http_get');
  PERFORM allgres_public.fn_grant_permission(v_ag, 'http_host', 'allowed.legacy-reserved.invalid');
  v_sid := (allgres_public.fn_create_session(v_ag, 'legacy reserved-name row')->>'session_id')::uuid;
  SELECT task_id INTO STRICT v_tid FROM allgres_private.tasks WHERE session_id = v_sid;
  PERFORM allgres_public.fn_next_step(v_tid);
  r := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"call_function"}',
    'parsed', jsonb_build_object('action', 'call_function', 'function', 'http_get',
      'args', jsonb_build_object('url', 'https://allowed.legacy-reserved.invalid/legacy'))));
  v_call := (r->>'call_id')::uuid;
  IF v_call IS NULL
     OR NOT EXISTS (SELECT 1 FROM allgres_private.outbound_calls
                    WHERE call_id = v_call AND kind = 'function' AND function = 'http_get'
                      AND url = 'https://allowed.legacy-reserved.invalid/legacy')
     OR EXISTS (SELECT 1 FROM allgres_private.function_calls WHERE task_id = v_tid) THEN
    RAISE EXCEPTION 'legacy reserved-name row shadowed the builtin http_get (submit=%)', r;
  END IF;

  -- permissions.options needs an admin once accounts exist; a throwaway one
  -- inside this rolled-back transaction (accounts need pgcrypto).
  IF EXISTS (SELECT 1 FROM allgres_private.users) THEN
    PERFORM allgres_public.fn_create_user('legacy_reserved_admin', 'legacy-reserved-pw1', 'admin');
    v_tok := allgres_public.fn_login('legacy_reserved_admin', 'legacy-reserved-pw1')->>'session_token';
  END IF;
  r := allgres.dashboard_rpc(jsonb_build_object('action', 'permissions.options', 'session_token', v_tok));
  IF r->>'ok' IS DISTINCT FROM 'true'
     OR (SELECT count(*) FROM jsonb_array_elements(r->'function_catalog') e WHERE e->>'name' = 'http_get') <> 1
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'function_catalog') e
                WHERE e->>'name' = 'http_get' AND e->>'kind' <> 'builtin') THEN
    RAISE EXCEPTION 'permissions.options lists the legacy reserved-name row: %', r->'function_catalog';
  END IF;
END
$block$;

ROLLBACK;

SELECT 'legacy reserved-name row ok' AS result;
