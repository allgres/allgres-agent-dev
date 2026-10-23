\set ON_ERROR_STOP on

-- Retire what the tests/*.sql suite leaves behind, so running it against a
-- database you also use does not leave e2e_*/smoke_* agents, their sessions,
-- and test-only functions in the dashboard. scripts/run_sql_tests.sh and CI
-- run this last; run it by hand after running any of the files yourself:
--
--   psql -v ON_ERROR_STOP=1 -f tests/cleanup.sql
--
-- Idempotent. It touches only the fixture names listed below, never a name
-- pattern, so an operator agent that happens to be called smoke_* is safe.
--
-- Rows that cannot be deleted are retired instead, the same way fn_selftest's
-- legacy fixtures are: execution_logs and audit_log are append-only by design
-- (forbid_log_mutation), and sessions/tasks cannot go without them. A
-- fixture agent is renamed to selftest_<name>_<id>, deactivated, and its
-- sessions are marked as selftest, which every operator-facing listing
-- already filters. Its grants, assignments, groups, canvas positions and
-- memories are deleted, as are the test-only functions and procedures.
-- The per-agent NOLOGIN role (allgres_agent_*) of a retired agent is kept:
-- it still owns that agent's history and is never used again.

BEGIN;

CREATE TEMP TABLE _fixture_agent_names(name text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO _fixture_agent_names VALUES
  ('e2e_mock_runner'),        -- e2e_mock.sql
  ('e2e_alpha_agent'),        -- e2e_mock.sql
  ('e2e_gamma_agent'),        -- e2e_mock.sql
  ('e2e_search_requester'),   -- e2e_mock.sql, capability_search_e2e.sql
  ('e2e_fx_runner'),          -- fixed_url_procedure_e2e.sql
  ('e2e_pb_runner'),          -- procedure_binding_e2e.sql
  ('e2e_recall_agent'),       -- e2e_mock.sql
  ('execution_safety_worker'),-- execution_safety_worker.sql
  ('smoke_role_agent_a'),     -- smoke.sql
  ('smoke_role_agent_b');     -- smoke.sql

CREATE TEMP TABLE _fixture_agents ON COMMIT DROP AS
SELECT a.agent_id, a.name
FROM allgres_private.agents a
JOIN _fixture_agent_names n USING (name)
WHERE NOT a.is_system;

-- Grants held by fixtures, and delegation grants pointing at them.
DELETE FROM allgres_private.permissions
WHERE agent_id IN (SELECT agent_id FROM _fixture_agents)
   OR (resource_type = 'agent' AND resource_ref IN (SELECT name FROM _fixture_agents));
DELETE FROM allgres_private.execution_rules WHERE agent_id IN (SELECT agent_id FROM _fixture_agents);
DELETE FROM allgres_private.user_agent_assignments WHERE agent_id IN (SELECT agent_id FROM _fixture_agents);
DELETE FROM allgres_private.user_agent_preferences WHERE agent_id IN (SELECT agent_id FROM _fixture_agents);
DELETE FROM allgres_private.agent_group_members WHERE agent_id IN (SELECT agent_id FROM _fixture_agents);
DELETE FROM allgres_private.canvas_positions
WHERE item_kind = 'agent' AND item_id IN (SELECT agent_id FROM _fixture_agents);
DELETE FROM allgres_private.agent_memories WHERE agent_id IN (SELECT agent_id FROM _fixture_agents);

-- Rename and deactivate. The suffix keeps names unique across repeated runs,
-- so the next run can create a fresh e2e_alpha_agent.
UPDATE allgres_private.agents a
SET name = 'selftest_' || a.name || '_' || left(replace(a.agent_id::text, '-', ''), 8),
    is_active = false
FROM _fixture_agents f
WHERE a.agent_id = f.agent_id;

-- Before this file existed, e2e_mock.sql ran on the seeded `analyst` agent.
-- Retire those sessions too (exact goals only). Its model setting cannot be
-- restored safely (the earlier value is unknown), so only point it out.
UPDATE allgres_private.sessions s
SET goal = 'selftest ' || s.goal
FROM allgres_private.agents a
WHERE a.agent_id = s.agent_id AND a.name = 'analyst' AND a.is_system IS NOT TRUE
  AND (s.goal = 'Return the Allgres MVP mock answer.' OR s.goal ~ '^load [0-9]+$');
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM allgres_private.policies p JOIN allgres_private.agents a USING (agent_id)
             WHERE a.name = 'analyst'
               AND p.llm_config = '{"provider":"allgres_mock","model":"allgres-mock","temperature":0,"max_tokens":128}'::jsonb) THEN
    RAISE NOTICE 'analyst still uses the model an older tests/e2e_mock.sql set (allgres_mock); change it in Agents if that was not intended';
  END IF;
END $$;

-- Prefix their sessions with "selftest", fail their open tasks, and cancel
-- their open sessions: the same normalization fn_selftest uses.
SELECT allgres_private.selftest_cleanup();

-- Test-only functions and procedures (and anything granted on them).
DELETE FROM allgres_private.permissions
WHERE (resource_type = 'procedure' AND resource_ref IN ('execution_safety_worker_proc', 'e2e-pb-proc', 'e2e-fx-proc'))
   OR (resource_type = 'function' AND (resource_ref IN ('alpha_governance_probe', 'e2e_pb_mcp', 'e2e_fx_get')
                                       OR resource_ref LIKE 'execution\_safety\_worker\_fn%'));
-- Outbound references do not cascade: remove them before their procedure,
-- Function, and connection. Sessions/tasks stay with the retired agent
-- above because their execution logs are append-only.
DELETE FROM allgres_private.outbound_calls
WHERE procedure_id IN (SELECT procedure_id FROM allgres_private.procedures WHERE name IN ('e2e-pb-proc', 'e2e-fx-proc'))
   OR procedure_function_id IN (SELECT function_id FROM allgres_private.functions WHERE name IN ('e2e_pb_mcp', 'e2e_fx_get'))
   OR connection_id IN (SELECT connection_id FROM allgres_private.api_connections WHERE name = 'e2e_pb_mock');
DELETE FROM allgres_private.procedures WHERE name IN ('e2e-pb-proc', 'e2e-fx-proc');
DELETE FROM allgres_private.functions WHERE name IN ('e2e_pb_mcp', 'e2e_fx_get');
DELETE FROM allgres_private.api_connections WHERE name = 'e2e_pb_mock';
DELETE FROM allgres_private.procedures WHERE name = 'execution_safety_worker_proc';
DELETE FROM allgres_private.functions
WHERE name = 'alpha_governance_probe' OR name LIKE 'execution\_safety\_worker\_fn%';

-- Test-only providers pointing at the built-in mock. Disabled rather than
-- deleted (calls and secrets may reference them); disabling the embedding
-- one matters most, since an enabled embedding provider is used for every
-- agent. allgres_mock itself is shared with scripts/bootstrap.sh's
-- first-run setup and is left alone.
UPDATE allgres_private.llm_providers
SET is_enabled = false
WHERE name IN ('allgres_mock_oauth', 'allgres_mock_embed');

SELECT allgres_private.sync_capability_index();

-- Nothing the suite created may still show up where an operator looks.
DO $$
DECLARE
  v_agents jsonb := allgres.dashboard_rpc('{"action":"agents.list"}'::jsonb)->'agents';
  v_left   text;
BEGIN
  SELECT string_agg(a->>'name', ', ') INTO v_left
  FROM jsonb_array_elements(COALESCE(v_agents, '[]'::jsonb)) a
  WHERE a->>'name' IN (SELECT name FROM _fixture_agent_names);
  IF v_left IS NOT NULL THEN
    RAISE EXCEPTION 'test cleanup left fixture agents visible: %', v_left;
  END IF;

  SELECT string_agg(name, ', ') INTO v_left
  FROM allgres_private.agents
  WHERE name IN (SELECT name FROM _fixture_agent_names);
  IF v_left IS NOT NULL THEN
    RAISE EXCEPTION 'test cleanup left fixture agents behind: %', v_left;
  END IF;

  SELECT string_agg(name, ', ') INTO v_left
  FROM allgres_private.functions
  WHERE name IN ('alpha_governance_probe', 'e2e_pb_mcp', 'e2e_fx_get') OR name LIKE 'execution\_safety\_worker\_fn%';
  IF v_left IS NOT NULL THEN
    RAISE EXCEPTION 'test cleanup left test functions behind: %', v_left;
  END IF;

  IF EXISTS (SELECT 1 FROM allgres_private.procedures WHERE name IN ('e2e-pb-proc', 'e2e-fx-proc'))
     OR EXISTS (SELECT 1 FROM allgres_private.api_connections WHERE name = 'e2e_pb_mock') THEN
    RAISE EXCEPTION 'test cleanup left procedure binding fixtures behind';
  END IF;

  IF EXISTS (SELECT 1 FROM allgres_private.sessions s
             JOIN allgres_private.agents a USING (agent_id)
             WHERE a.name LIKE 'selftest\_%' AND s.status = 'open') THEN
    RAISE EXCEPTION 'test cleanup left fixture sessions open';
  END IF;
END $$;

COMMIT;

SELECT 'cleanup ok' AS result;
