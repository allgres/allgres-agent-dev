-- Building capabilities by conversation (stage 4, docs/creator.md): what a
-- person sees about a proposed function or usage document before deciding,
-- and handing the approved result to the agents that should have it.
--
-- Nothing a creator proposes runs before a person approves it, and the check
-- below never runs the proposed code either: it reads it and compiles it in a
-- throw-away object that is rolled back at once.

-- NULL when the body compiles, otherwise what PostgreSQL said.
CREATE OR REPLACE FUNCTION allgres_private.dry_compile_plpgsql(p_body text)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_temp
AS $fn$
BEGIN
  BEGIN
    PERFORM set_config('check_function_bodies', 'on', true);
    EXECUTE format('CREATE FUNCTION pg_temp.allgres_dry_check(p_args jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER AS %L', p_body);
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '__dry_compile_ok__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = '__dry_compile_ok__' THEN
      RETURN NULL;
    END IF;
    RETURN left(SQLERRM, 300);
  END;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.looks_like_secret(p_text text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT COALESCE(p_text, '') ~* '(api[_-]?key\s*[:=]|secret\s*[:=]|passw(or)?d\s*[:=]|bearer\s+[a-z0-9._-]{12,}|sk-[a-z0-9]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY)'
$fn$;

-- {"ok": bool, "ran": false, "checks": [{"check", "ok", "detail"}]}. A failed
-- check is a reason to reject; a warning is only shown.
CREATE OR REPLACE FUNCTION allgres_private.proposal_test_report(p_kind text, p_changes jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_checks jsonb := '[]'::jsonb;
  v_err text;
  v_body text := p_changes->>'body';
  v_text text;
BEGIN
  IF p_kind IN ('create_function', 'update_function') AND v_body IS NOT NULL THEN
    v_err := NULL;
    BEGIN PERFORM allgres_private.validate_function_body(v_body);
    EXCEPTION WHEN others THEN v_err := SQLERRM; END;
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('check', 'body rules', 'ok', v_err IS NULL,
      'detail', COALESCE(v_err, 'no SECURITY DEFINER, no role change')));
    v_err := allgres_private.dry_compile_plpgsql(v_body);
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('check', 'compiles', 'ok', v_err IS NULL,
      'detail', COALESCE(v_err, 'PostgreSQL accepted it (compiled, then thrown away)')));
    v_text := v_body;
  ELSIF p_kind = 'create_procedure' THEN
    v_text := p_changes->>'content';
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('check', 'has content', 'ok', btrim(COALESCE(v_text, '')) <> '',
      'detail', length(COALESCE(v_text, '')) || ' characters'));
  ELSE
    RETURN NULL;
  END IF;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object('check', 'no secret written in', 'ok', NOT allgres_private.looks_like_secret(v_text),
    'detail', CASE WHEN allgres_private.looks_like_secret(v_text) THEN 'it looks like a key, password or token is written into the text'
                   ELSE 'nothing that looks like a key or password' END));
  RETURN jsonb_build_object(
    'ok', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_checks) c WHERE NOT (c->>'ok')::boolean),
    'ran', false,
    'note', 'The code was read and compiled, not run. It runs only after approval, under the rights of the agent that calls it.',
    'checks', v_checks);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.change_proposals_test_report()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  BEGIN
    NEW.test_report := allgres_private.proposal_test_report(NEW.kind, NEW.proposed_changes);
  EXCEPTION WHEN others THEN
    NEW.test_report := jsonb_build_object('ok', false, 'ran', false, 'checks',
      jsonb_build_array(jsonb_build_object('check', 'report', 'ok', false, 'detail', left(SQLERRM, 200))));
  END;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS change_proposals_test_report ON allgres_private.change_proposals;
CREATE TRIGGER change_proposals_test_report
  BEFORE INSERT ON allgres_private.change_proposals
  FOR EACH ROW EXECUTE FUNCTION allgres_private.change_proposals_test_report();

-- After approval: give the new function or usage document to the agents a
-- person picks. A system agent is never given one this way.
CREATE OR REPLACE FUNCTION allgres_public.fn_proposal_grant(p_proposal_id uuid, p_agent_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r allgres_private.change_proposals%ROWTYPE;
  v_type text;
  v_name text;
  v_agent uuid;
  v_granted text[] := ARRAY[]::text[];
  v_aname text;
BEGIN
  SELECT * INTO r FROM allgres_private.change_proposals WHERE proposal_id = p_proposal_id;
  IF NOT FOUND OR r.status <> 'approved' OR r.result IS NULL OR r.result->>'kind' NOT IN ('function', 'procedure') THEN
    RAISE EXCEPTION 'only an approved function or usage document can be handed out' USING ERRCODE = 'P0001';
  END IF;
  v_type := r.result->>'kind';
  v_name := r.result->>'name';
  FOREACH v_agent IN ARRAY COALESCE(p_agent_ids, ARRAY[]::uuid[]) LOOP
    SELECT name INTO v_aname FROM allgres_private.agents WHERE agent_id = v_agent AND NOT is_system AND is_active;
    IF v_aname IS NULL THEN
      RAISE EXCEPTION 'pick active agents that are not system agents' USING ERRCODE = 'P0001';
    END IF;
    PERFORM allgres_public.fn_grant_permission(v_agent, v_type, v_name);
    v_granted := v_granted || v_aname;
  END LOOP;
  UPDATE allgres_private.change_proposals
  SET result = result || jsonb_build_object('granted_to', COALESCE(result->'granted_to', '[]'::jsonb) || to_jsonb(v_granted))
  WHERE proposal_id = p_proposal_id;
  RETURN jsonb_build_object('ok', true, 'granted_to', to_jsonb(v_granted));
END;
$fn$;
