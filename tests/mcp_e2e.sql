\set ON_ERROR_STOP on

-- Requires the real background worker and the built-in mock MCP servers
-- (like e2e_mock.sql): discovery goes through the worker's HTTP pool against
-- the four mock variants, so the plain, event-stream, stateless and
-- authenticated handshakes are all exercised for real.
DELETE FROM allgres_private.api_connections WHERE name LIKE 'mcp_e2e_%';

DO $$
DECLARE
  v record;
  v_id uuid;
BEGIN
  FOR v IN SELECT * FROM (VALUES
    ('mcp_e2e_plain',     '/mock/mcp',           'none',          NULL,         'ok'),
    ('mcp_e2e_sse',       '/mock/mcp-sse',       'none',          NULL,         'ok'),
    ('mcp_e2e_stateless', '/mock/mcp-stateless', 'none',          NULL,         'ok'),
    ('mcp_e2e_auth',      '/mock/mcp-auth',      'authorization', 'mcp-secret', 'ok'),
    ('mcp_e2e_badkey',    '/mock/mcp-auth',      'authorization', 'wrong',      'auth_needed')
  ) AS x(name, path, auth, key, expected) LOOP
    v_id := (allgres_public.fn_mcp_connect(v.name, 'http://127.0.0.1:8088' || v.path, v.auth, v.key, true)->>'connection_id')::uuid;
    RAISE NOTICE 'queued %', v.name;
  END LOOP;
END $$;

DO $$
BEGIN
  FOR i IN 1..40 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM allgres_private.api_connections
                          WHERE name LIKE 'mcp_e2e_%' AND health = 'unknown');
    PERFORM pg_sleep(0.5);
    -- A transaction snapshot would hide the worker's commit; end it.
    COMMIT;
  END LOOP;
END $$;

DO $$
DECLARE
  r record;
  v_bad text;
BEGIN
  FOR r IN SELECT c.name, c.health, c.health_detail,
                  (SELECT count(*) FROM allgres_private.mcp_tools t WHERE t.connection_id = c.connection_id) AS tools,
                  (SELECT suggested_risk FROM allgres_private.mcp_tools t WHERE t.connection_id = c.connection_id AND tool_name = 'move_arm') AS arm
           FROM allgres_private.api_connections c WHERE c.name LIKE 'mcp_e2e_%' ORDER BY c.name LOOP
    IF r.name = 'mcp_e2e_badkey' THEN
      IF r.health <> 'auth_needed' OR r.tools <> 0 THEN
        v_bad := format('%s: health %s (%s), %s tools', r.name, r.health, r.health_detail, r.tools);
      END IF;
    ELSIF r.health <> 'ok' OR r.tools <> 3 OR r.arm IS DISTINCT FROM 'physical' THEN
      v_bad := format('%s: health %s (%s), %s tools, move_arm %s', r.name, r.health, r.health_detail, r.tools, r.arm);
    END IF;
    EXIT WHEN v_bad IS NOT NULL;
  END LOOP;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MCP e2e failed: %', v_bad; END IF;
END $$;

DELETE FROM allgres_private.api_connections WHERE name LIKE 'mcp_e2e_%';
SELECT 'mcp e2e ok' AS result;
