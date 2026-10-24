\set ON_ERROR_STOP on

-- The executor-only field outbound_calls.error_kind: fn_complete_outbound
-- accepts a non-NULL p_error_kind only inside the allgres runtime worker
-- process (allgres.is_runtime_worker()). Every role that holds EXECUTE on
-- the 4-argument function -- superuser, allgres_owner, allgres_operator,
-- and allgres_worker itself (the role, assumed with SET ROLE from an
-- ordinary backend, is not the process) -- must be refused with 42501 and
-- that exact message, and the in_flight row must stay exactly as it was.
--
-- Without this, a gate that never fires (IF false) passes every other
-- test: they only ever see error_kind written by the real worker.
--
-- One transaction, rolled back: the runtime worker never sees the fixture.
BEGIN;

DO $setup$
DECLARE
  a uuid; t uuid; c uuid; r text;
BEGIN
  a := (allgres_public.fn_create_agent('outbound_error_kind_gate_fixture')->>'agent_id')::uuid;
  t := (allgres_public.fn_create_session(a, 'outbound error_kind gate')->>'task_id')::uuid;
  INSERT INTO allgres_private.outbound_calls(task_id, kind, url, status)
    VALUES (t, 'function', 'http://outbound-error-kind-gate.allgres-test.invalid/', 'in_flight')
    RETURNING call_id INTO c;
  PERFORM set_config('allgres_test.gate_call', c::text, true);
  PERFORM set_config('allgres_test.gate_row',
    (SELECT row_to_json(o)::text FROM allgres_private.outbound_calls o WHERE call_id = c), true);

  -- The refusal must come from the gate, not from a missing EXECUTE grant
  -- (which is also 42501, with another message): each role below can call it.
  FOREACH r IN ARRAY ARRAY['allgres_owner', 'allgres_operator', 'allgres_worker'] LOOP
    IF NOT has_function_privilege(r, 'allgres_public.fn_complete_outbound(uuid, int, text, text)', 'EXECUTE') THEN
      RAISE EXCEPTION 'fixture: % has no EXECUTE on fn_complete_outbound(uuid,int,text,text); the gate test would test the grant instead', r;
    END IF;
  END LOOP;
  IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION 'fixture: this test must start as a superuser';
  END IF;
END
$setup$;

-- Helpers live in a scratch schema that the ROLLBACK removes (a pg_temp
-- function cannot be granted to the roles below).
CREATE SCHEMA outbound_error_kind_gate_test;
GRANT USAGE ON SCHEMA outbound_error_kind_gate_test TO allgres_owner, allgres_operator, allgres_worker;

-- One attempt, as whatever role is current. A forged 'dns' and the other
-- kinds are all refused; NULL is the normal (non-worker) path and is not
-- tried here because it would legitimately complete the row.
CREATE FUNCTION outbound_error_kind_gate_test.gate_attempt(p_kind text) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  v_call uuid := current_setting('allgres_test.gate_call')::uuid;
  v_state text; v_msg text;
BEGIN
  BEGIN
    PERFORM allgres_public.fn_complete_outbound(v_call, 0, 'forged by ' || current_user, p_kind);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'gate open: % (ordinary backend %) completed call % with error_kind %',
      current_user, pg_backend_pid(), v_call, p_kind;
  END IF;
  IF v_state <> '42501'
     OR v_msg <> 'fn_complete_outbound: error_kind is recorded only by the allgres runtime worker' THEN
    RAISE EXCEPTION 'as %, error_kind %: expected 42501 "fn_complete_outbound: error_kind is recorded only by the allgres runtime worker", got % "%"',
      current_user, p_kind, v_state, v_msg;
  END IF;
  RETURN current_user || ':' || p_kind || ' refused';
END
$fn$;
GRANT EXECUTE ON FUNCTION outbound_error_kind_gate_test.gate_attempt(text) TO allgres_owner, allgres_operator, allgres_worker;

-- The row, checked as superuser after every role's attempts.
CREATE FUNCTION outbound_error_kind_gate_test.gate_row_unchanged(p_after text) RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
  v_now text;
BEGIN
  SELECT row_to_json(o)::text INTO v_now FROM allgres_private.outbound_calls o
   WHERE call_id = current_setting('allgres_test.gate_call')::uuid;
  IF v_now IS DISTINCT FROM current_setting('allgres_test.gate_row') THEN
    RAISE EXCEPTION 'after %: outbound row changed: % -> %', p_after,
      current_setting('allgres_test.gate_row'), v_now;
  END IF;
END
$fn$;

-- superuser (the extension owner's peer; also the CREATE EXTENSION user)
SELECT outbound_error_kind_gate_test.gate_attempt(k) FROM unnest(ARRAY['dns', 'blocked_address', 'connect', 'timeout', 'cancelled', 'transport']) k;
SELECT outbound_error_kind_gate_test.gate_row_unchanged('superuser');

SET ROLE allgres_owner;
SELECT outbound_error_kind_gate_test.gate_attempt('dns');
SELECT outbound_error_kind_gate_test.gate_attempt('blocked_address');
RESET ROLE;
SELECT outbound_error_kind_gate_test.gate_row_unchanged('allgres_owner');

SET ROLE allgres_operator;
SELECT outbound_error_kind_gate_test.gate_attempt('dns');
SELECT outbound_error_kind_gate_test.gate_attempt('blocked_address');
RESET ROLE;
SELECT outbound_error_kind_gate_test.gate_row_unchanged('allgres_operator');

SET ROLE allgres_worker;
SELECT outbound_error_kind_gate_test.gate_attempt('dns');
SELECT outbound_error_kind_gate_test.gate_attempt('blocked_address');
RESET ROLE;
SELECT outbound_error_kind_gate_test.gate_row_unchanged('allgres_worker');

ROLLBACK;
