\set ON_ERROR_STOP on
-- Needs a resolver that fails .invalid lookups; stops loudly otherwise.
\ir require_failing_dns.sql

-- An install created before Function names were reserved can already have a
-- row named like a builtin. This build's trigger refuses writing one, so the
-- legacy row is inserted with triggers skipped (session_replication_role =
-- replica, superuser only). Part 1 (enqueue, claim, catalog) runs in one
-- transaction that is rolled back. Part 2 must commit so the Rust worker can
-- see the call and reach the executor; it runs in database postgres and
-- removes its legacy row itself (tests/cleanup.sql also does). Kept out of
-- fn_selftest so the selftest never needs ALTER TABLE or an exclusive lock on
-- allgres_private.functions.
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
  v_other_tid uuid;
  v_other_call uuid;
  v_claim jsonb;
  v_claimed jsonb := '[]';
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

  -- (a) The claim hands it out as the builtin outbound call. Other queued
  -- rows this claims are rolled back with the transaction.
  FOR i IN 1..20 LOOP
    v_claim := allgres_public.fn_claim_outbound(16);
    v_claimed := v_claimed || COALESCE(v_claim->'calls', '[]');
    EXIT WHEN v_claimed @> jsonb_build_array(jsonb_build_object('call_id', v_call))
      OR (v_claim->>'count')::int = 0;
  END LOOP;
  IF NOT v_claimed @> jsonb_build_array(jsonb_build_object('call_id', v_call, 'function', 'http_get',
         'kind', 'function', 'url', 'https://allowed.legacy-reserved.invalid/legacy'))
     OR NOT EXISTS (SELECT 1 FROM allgres_private.outbound_calls WHERE call_id = v_call AND status = 'in_flight')
     OR EXISTS (SELECT 1 FROM allgres_private.function_calls WHERE task_id = v_tid)
     OR EXISTS (SELECT 1 FROM allgres_private.execution_logs WHERE task_id = v_tid AND role = 'error'
                  AND content->>'reason' IN ('function_not_permitted', 'http_host_not_permitted',
                                             'function_not_built', 'unknown_function')) THEN
    RAISE EXCEPTION 'legacy reserved-name row: builtin http_get was not handed out at claim (claimed=%)', v_claimed;
  END IF;

  -- (b1) A host never granted is refused at enqueue (fn_submit_result checks
  -- http_host before queueing a direct http_get): no call, an error log.
  v_sid := (allgres_public.fn_create_session(v_ag, 'legacy reserved-name row, other host')->>'session_id')::uuid;
  SELECT task_id INTO STRICT v_other_tid FROM allgres_private.tasks WHERE session_id = v_sid;
  PERFORM allgres_public.fn_next_step(v_other_tid);
  r := allgres_public.fn_submit_result(v_other_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"call_function"}',
    'parsed', jsonb_build_object('action', 'call_function', 'function', 'http_get',
      'args', jsonb_build_object('url', 'https://other.legacy-reserved.invalid/x'))));
  IF r ? 'call_id'
     OR EXISTS (SELECT 1 FROM allgres_private.outbound_calls WHERE task_id = v_other_tid)
     OR EXISTS (SELECT 1 FROM allgres_private.function_calls WHERE task_id = v_other_tid)
     OR NOT EXISTS (SELECT 1 FROM allgres_private.execution_logs WHERE task_id = v_other_tid AND role = 'error'
                      AND content->>'reason' = 'http_host_not_permitted'
                      AND content->>'host' = 'other.legacy-reserved.invalid') THEN
    RAISE EXCEPTION 'legacy reserved-name row: non-granted host was not refused at enqueue (submit=%)', r;
  END IF;

  -- (b2) A host revoked between enqueue and claim is lost at claim with
  -- http_host_not_permitted (the claim guard's own host check).
  PERFORM allgres_public.fn_grant_permission(v_ag, 'http_host', 'revoked.legacy-reserved.invalid');
  v_sid := (allgres_public.fn_create_session(v_ag, 'legacy reserved-name row, revoked host')->>'session_id')::uuid;
  SELECT task_id INTO STRICT v_other_tid FROM allgres_private.tasks WHERE session_id = v_sid;
  PERFORM allgres_public.fn_next_step(v_other_tid);
  r := allgres_public.fn_submit_result(v_other_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"call_function"}',
    'parsed', jsonb_build_object('action', 'call_function', 'function', 'http_get',
      'args', jsonb_build_object('url', 'https://revoked.legacy-reserved.invalid/x'))));
  v_other_call := (r->>'call_id')::uuid;
  IF v_other_call IS NULL OR NOT EXISTS (SELECT 1 FROM allgres_private.outbound_calls
       WHERE call_id = v_other_call AND function = 'http_get' AND kind = 'function' AND status = 'queued') THEN
    RAISE EXCEPTION 'legacy reserved-name row: revoked-host call was not queued as builtin (submit=%)', r;
  END IF;
  PERFORM allgres_public.fn_revoke_permission(v_ag, 'http_host', 'revoked.legacy-reserved.invalid');
  v_claimed := '[]';
  FOR i IN 1..20 LOOP
    v_claim := allgres_public.fn_claim_outbound(16);
    v_claimed := v_claimed || COALESCE(v_claim->'calls', '[]');
    EXIT WHEN EXISTS (SELECT 1 FROM allgres_private.outbound_calls WHERE call_id = v_other_call AND status <> 'queued')
      OR (v_claim->>'count')::int = 0;
  END LOOP;
  IF v_claimed @> jsonb_build_array(jsonb_build_object('call_id', v_other_call))
     OR NOT EXISTS (SELECT 1 FROM allgres_private.outbound_calls WHERE call_id = v_other_call AND status = 'lost')
     OR NOT EXISTS (SELECT 1 FROM allgres_private.execution_logs WHERE task_id = v_other_tid AND role = 'error'
                      AND content->>'reason' = 'http_host_not_permitted'
                      AND content->>'call_id' = v_other_call::text) THEN
    RAISE EXCEPTION 'legacy reserved-name row: revoked-host call was not lost at claim (claimed=%)', v_claimed;
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

-- Part 2 (c): reach the executor with the legacy row present. Needs committed
-- rows: the worker only sees committed calls, and only in database postgres.
-- Same proof as fixed_url_procedure_e2e.sql: an RFC 2606 .invalid https host
-- (http_get never reaches private addresses), so the executor's own DNS
-- failure is what fn_complete_outbound records -- error_kind = 'dns', set
-- only by the runtime worker, not resolver wording (see that file); this
-- file never calls a claim or completion function here.
DO $block$
BEGIN
  IF current_database() <> 'postgres' THEN
    RAISE EXCEPTION 'legacy reserved-name e2e requires database postgres (the runtime worker database)';
  END IF;
END
$block$;

BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO allgres_private.functions(name, description, handler, body, build_status)
VALUES ('http_get', 'legacy builtin collision e2e', 'plpgsql', 'BEGIN RETURN p_args; END;', 'built');
COMMIT;

DO $block$
DECLARE
  v_ag uuid;
BEGIN
  SELECT agent_id INTO v_ag FROM allgres_private.agents WHERE name = 'e2e_legacy_reserved_runner';
  IF NOT FOUND THEN
    v_ag := (allgres_public.fn_create_agent('e2e_legacy_reserved_runner', 'HTTP')->>'agent_id')::uuid;
  END IF;
  DELETE FROM allgres_private.permissions WHERE agent_id = v_ag;
  PERFORM allgres_public.fn_grant_permission(v_ag, 'function', 'http_get');
  PERFORM allgres_public.fn_grant_permission(v_ag, 'http_host', 'e2e-legacy.allgres-test.invalid');
END
$block$;

CREATE TEMP TABLE _legacy_reserved_e2e(task_id uuid, call_id uuid);
SELECT (allgres_public.fn_create_session(
  (SELECT agent_id FROM allgres_private.agents WHERE name = 'e2e_legacy_reserved_runner'),
  'legacy reserved-name e2e'
)->>'session_id') AS legacy_session_id \gset
INSERT INTO _legacy_reserved_e2e(task_id)
SELECT task_id FROM allgres_private.tasks WHERE session_id = :'legacy_session_id'::uuid;
SELECT allgres_public.fn_next_step(task_id) FROM _legacy_reserved_e2e;
UPDATE _legacy_reserved_e2e
SET call_id = (allgres_public.fn_submit_result(task_id, jsonb_build_object(
  'type', 'llm_response', 'content', '{"action":"call_function","function":"http_get"}',
  'parsed', jsonb_build_object('action', 'call_function', 'function', 'http_get',
    'args', '{"url":"https://e2e-legacy.allgres-test.invalid/builtin?x=1"}'::jsonb)
))->>'call_id')::uuid;

DO $block$
DECLARE
  v_task uuid;
  v_call uuid;
  v_status text;
  v_body text;
  v_kind text;
BEGIN
  SELECT task_id, call_id INTO STRICT v_task, v_call FROM _legacy_reserved_e2e;
  IF v_call IS NULL OR EXISTS (SELECT 1 FROM allgres_private.function_calls WHERE task_id = v_task) THEN
    RAISE EXCEPTION 'legacy reserved-name e2e: builtin http_get was not enqueued (task=%, call=%)', v_task, v_call;
  END IF;
  FOR i IN 1..200 LOOP
    SELECT status, response_body, error_kind INTO v_status, v_body, v_kind
    FROM allgres_private.outbound_calls WHERE call_id = v_call AND task_id = v_task;
    EXIT WHEN v_status NOT IN ('queued', 'in_flight');
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF v_status IS DISTINCT FROM 'harvested'
     OR v_kind IS DISTINCT FROM 'dns'
     OR COALESCE(v_body, '') = ''
     OR NOT EXISTS (SELECT 1 FROM allgres_private.outbound_calls
                    WHERE call_id = v_call AND kind = 'function' AND function = 'http_get'
                      AND url = 'https://e2e-legacy.allgres-test.invalid/builtin?x=1'
                      AND procedure_id IS NULL AND NOT allow_private AND response_status = 0)
     OR EXISTS (SELECT 1 FROM allgres_private.function_calls WHERE task_id = v_task)
     OR EXISTS (SELECT 1 FROM allgres_private.execution_logs WHERE task_id = v_task AND role = 'error'
                  AND content->>'reason' IN ('function_not_permitted', 'http_host_not_permitted',
                                             'function_not_built', 'unknown_function')) THEN
    RAISE EXCEPTION 'legacy reserved-name e2e: builtin http_get did not reach the executor (call=%, status=%, error_kind=%, body=%)',
      v_call, v_status, v_kind, v_body;
  END IF;
END
$block$;

DROP TABLE _legacy_reserved_e2e;
DELETE FROM allgres_private.functions
WHERE name = 'http_get' AND handler = 'plpgsql' AND description = 'legacy builtin collision e2e';

SELECT 'legacy reserved-name row ok' AS result;
