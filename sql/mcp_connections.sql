-- MCP servers as connections: discovery, risk levels, registration
-- (docs/stage3-design.md, slice 3a).
--
-- An MCP server is an api_connections row of kind 'mcp'. Allgres never runs
-- the server and never speaks to it from inside PostgreSQL: a discovery asks
-- the runtime worker to send a JSON-RPC tools/list through the same HTTP
-- handshake an mcp_call Function uses (src/outbound.rs, kind "mcp"), and the
-- reply lands in mcp_tools.
--
-- What a server says about its own tools is a hint, not a fact. Every tool
-- starts with no confirmed risk level and cannot be registered as a Function
-- until a person sets one. A tool that is write or physical always needs a
-- human approval before it runs (functions.requires_approval, checked in the
-- execution gate). If a registered tool's description or schema changes, the
-- Function is switched off until a person registers it again.
--
-- Loaded after sql/decision_records.sql and before sql/selftest.sql
-- (src/lib.rs). The final ownership and REVOKE pass in
-- sql/grants_and_facade.sql covers these objects like any other.

ALTER TABLE allgres_private.api_connections
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'http' CHECK (kind IN ('http', 'mcp')),
  ADD COLUMN IF NOT EXISTS health text NOT NULL DEFAULT 'unknown'
    CHECK (health IN ('unknown', 'ok', 'auth_needed', 'unreachable', 'changed')),
  ADD COLUMN IF NOT EXISTS health_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS health_detail text;

-- What a provider says its models cost, read from its model list when a
-- connection test succeeds: {"model": {"input_per_1k": n, "output_per_1k": n}}.
-- A claim by the provider, not a price: a person accepts it.
ALTER TABLE allgres_private.llm_providers
  ADD COLUMN IF NOT EXISTS reported_prices jsonb NOT NULL DEFAULT '{}'::jsonb;

-- A Function that must be approved by a person every time it runs, whatever
-- the calling agent's own execution rules say.
ALTER TABLE allgres_private.functions
  ADD COLUMN IF NOT EXISTS requires_approval boolean NOT NULL DEFAULT false;

-- Suggestions only: a pattern on the tool name proposes a risk level for a
-- person to confirm. Data, so an operator can tune it without a release.
CREATE TABLE IF NOT EXISTS allgres_private.mcp_risk_rules (
  rule_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pattern    text NOT NULL,
  risk       text NOT NULL CHECK (risk IN ('read', 'write', 'physical')),
  priority   int NOT NULL DEFAULT 100,
  UNIQUE (pattern, risk)
);

INSERT INTO allgres_private.mcp_risk_rules (pattern, risk, priority) VALUES
  ('(^|[_.-])(move|actuate|jog|home|spin|power|drive|arm|disarm|fire|launch|open|close|valve|pump|motor|robot|gripper|heater|relay|switch|calibrate|reboot|shutdown)([_.-]|$)', 'physical', 10),
  ('(^|[_.-])(create|update|delete|remove|write|send|post|put|set|run|execute|exec|deploy|transfer|pay|publish|drop|kill|restart|start|stop|cancel|approve|commit|push|install|upload|edit|insert|apply|reset|clear|submit)([_.-]|$)', 'write', 20),
  ('(^|[_.-])(get|list|read|search|find|fetch|query|describe|show|lookup|check|status|view|count|browse|summari[sz]e|extract|retrieve|monitor|measure)([_.-]|$)', 'read', 30)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS allgres_private.mcp_tools (
  connection_id          uuid NOT NULL REFERENCES allgres_private.api_connections(connection_id) ON DELETE CASCADE,
  tool_name              text NOT NULL,
  description            text NOT NULL DEFAULT '',
  input_schema           jsonb NOT NULL DEFAULT '{}'::jsonb,
  server_hints           jsonb NOT NULL DEFAULT '{}'::jsonb,
  fingerprint            text NOT NULL,
  suggested_risk         text CHECK (suggested_risk IN ('read', 'write', 'physical')),
  -- NULL until a person confirms it. A tool with no risk cannot be registered.
  risk                   text CHECK (risk IN ('read', 'write', 'physical')),
  approval               text NOT NULL DEFAULT 'required' CHECK (approval IN ('none', 'required')),
  status                 text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'registered', 'changed', 'removed')),
  registered_function_id uuid REFERENCES allgres_private.functions(function_id) ON DELETE SET NULL,
  -- An mcp_call Function runs only through a Procedure bound to it (the same
  -- rule http_get follows), so registering a tool also creates that
  -- Procedure. It is what an agent is given.
  registered_procedure_id uuid REFERENCES allgres_private.procedures(procedure_id) ON DELETE SET NULL,
  last_seen_scan         uuid,
  first_seen_at          timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (connection_id, tool_name),
  -- Write and physical tools are never allowed to run without approval.
  CHECK (risk IS NULL OR risk = 'read' OR approval = 'required')
);

-- Discovery queue: same claim/complete/'lost'-reclaim shape as provider_probes.
CREATE TABLE IF NOT EXISTS allgres_private.mcp_probes (
  call_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id    uuid NOT NULL REFERENCES allgres_private.api_connections(connection_id) ON DELETE CASCADE,
  scan_id          uuid NOT NULL,
  -- 'discover' asks an MCP server for its tools; 'ping' is the plain "can
  -- this connection be reached with its credential" test (a GET).
  purpose          text NOT NULL DEFAULT 'discover' CHECK (purpose IN ('discover', 'ping')),
  cursor           text,
  url              text NOT NULL,
  allow_private    boolean NOT NULL DEFAULT false,
  status           text NOT NULL CHECK (status IN ('queued', 'in_flight', 'harvested', 'lost')),
  response_status  int,
  error            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS mcp_probes_ready_idx
  ON allgres_private.mcp_probes (created_at) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS mcp_probes_inflight_idx
  ON allgres_private.mcp_probes (updated_at) WHERE status = 'in_flight';

-- The JSON-RPC message inside an MCP reply. A Streamable HTTP server may
-- answer with plain JSON or with a text/event-stream whose "data:" lines
-- carry the message; both come through the worker as the response text.
CREATE OR REPLACE FUNCTION allgres_private.mcp_json_body(p_body text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  v jsonb;
  v_line text;
  v_out jsonb;
BEGIN
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RETURN NULL;
  END IF;
  BEGIN
    RETURN p_body::jsonb;
  EXCEPTION WHEN others THEN
    NULL;
  END;
  FOR v_line IN SELECT regexp_split_to_table(p_body, E'\r?\n') LOOP
    IF v_line LIKE 'data:%' THEN
      BEGIN
        v := ltrim(substr(v_line, 6))::jsonb;
        IF jsonb_typeof(v) = 'object' AND (v ? 'result' OR v ? 'error') THEN
          v_out := v;
        END IF;
      EXCEPTION WHEN others THEN
        NULL;
      END;
    END IF;
  END LOOP;
  RETURN v_out;
END;
$fn$;

-- Proposes a risk level from the tool name and what the server hinted. Never
-- decides: the answer is stored as suggested_risk and a person confirms it.
-- The most dangerous match wins, and a destructive hint is never read.
CREATE OR REPLACE FUNCTION allgres_private.mcp_suggest_risk(p_name text, p_hints jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_risk text;
BEGIN
  SELECT r.risk INTO v_risk
  FROM allgres_private.mcp_risk_rules r
  WHERE lower(p_name) ~ r.pattern
  ORDER BY r.priority
  LIMIT 1;
  IF COALESCE((p_hints->>'destructiveHint')::boolean, false) AND COALESCE(v_risk, 'read') = 'read' THEN
    v_risk := 'write';
  END IF;
  IF v_risk IS NULL AND COALESCE((p_hints->>'readOnlyHint')::boolean, false) THEN
    v_risk := 'read';
  END IF;
  RETURN v_risk;
END;
$fn$;

-- The tools/list request every discovery sends. _meta carries the protocol
-- version and client identity the 2026-07-28 revision asks for on every
-- request; a server that still expects the older initialize handshake gets it
-- from the worker and ignores _meta.
CREATE OR REPLACE FUNCTION allgres_private.mcp_list_request(p_cursor text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT jsonb_build_object(
    'jsonrpc', '2.0', 'id', 'allgres-tools-list', 'method', 'tools/list',
    'params', jsonb_strip_nulls(jsonb_build_object(
      'cursor', p_cursor,
      '_meta', jsonb_build_object(
        'protocolVersion', '2026-07-28',
        'clientInfo', jsonb_build_object('name', 'allgres'),
        'capabilities', '{}'::jsonb
      )
    ))
  )
$fn$;

-- Queues a discovery for one MCP server (first page; later pages are queued
-- by the completion). A newer scan supersedes an unfinished one.
CREATE OR REPLACE FUNCTION allgres_public.fn_mcp_discover_start(p_connection_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  c allgres_private.api_connections%ROWTYPE;
  v_reason text;
  v_call uuid;
  v_scan uuid := gen_random_uuid();
BEGIN
  SELECT * INTO c FROM allgres_private.api_connections WHERE connection_id = p_connection_id;
  IF NOT FOUND OR c.kind <> 'mcp' THEN
    RAISE EXCEPTION 'MCP server not found' USING ERRCODE = 'P0001';
  END IF;
  v_reason := allgres_private.check_outbound_url(c.base_url, c.allow_private_network);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'MCP endpoint rejected: %', v_reason USING ERRCODE = 'P0001';
  END IF;

  UPDATE allgres_private.mcp_probes
  SET status = 'lost', error = 'superseded by a newer discovery', updated_at = now()
  WHERE connection_id = p_connection_id AND status IN ('queued', 'in_flight');

  INSERT INTO allgres_private.mcp_probes (connection_id, scan_id, url, allow_private, status)
  VALUES (p_connection_id, v_scan, c.base_url, c.allow_private_network, 'queued')
  RETURNING call_id INTO v_call;

  PERFORM allgres_private.audit('mcp.discover_start', jsonb_build_object(
    'connection_id', p_connection_id, 'call_id', v_call));
  RETURN jsonb_build_object('ok', true, 'call_id', v_call, 'connection_id', p_connection_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_claim_mcp_probe(p_limit int DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  v_out jsonb := '[]'::jsonb;
  v_n int := 0;
  v_key text;
  v_headers jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  FOR r IN
    SELECT mp.call_id, mp.connection_id, mp.url, mp.cursor, mp.allow_private, mp.purpose, c.auth_kind, c.is_enabled
    FROM allgres_private.mcp_probes mp
    JOIN allgres_private.api_connections c ON c.connection_id = mp.connection_id
    WHERE mp.status = 'queued'
    ORDER BY mp.created_at
    FOR UPDATE OF mp SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 4), 16))
  LOOP
    IF NOT r.is_enabled THEN
      UPDATE allgres_private.mcp_probes
      SET status = 'lost', error = 'connection disabled', updated_at = now()
      WHERE call_id = r.call_id;
      CONTINUE;
    END IF;
    UPDATE allgres_private.mcp_probes
    SET status = 'in_flight', updated_at = now()
    WHERE call_id = r.call_id;

    v_headers := jsonb_build_object(
      'accept', 'application/json, text/event-stream',
      'content-type', 'application/json');
    IF r.auth_kind <> 'none' THEN
      v_key := COALESCE(allgres_private.connection_secret(r.connection_id), '');
      -- An OAuth connection with no token yet sends nothing and gets a 401.
      IF v_key <> '' OR r.auth_kind <> 'oauth' THEN
        v_headers := v_headers || jsonb_build_object(
          allgres_private.conn_header_kind(r.auth_kind),
          CASE WHEN r.auth_kind = 'x-api-key' THEN v_key ELSE 'Bearer ' || v_key END);
      END IF;
    END IF;
    IF r.purpose = 'ping' THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'call_id', r.call_id, 'kind', 'function', 'method', 'GET', 'url', r.url,
        'headers', v_headers - 'content-type', 'allow_private', r.allow_private));
    ELSE
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'call_id', r.call_id,
        'method', 'POST',
        'url', r.url,
        'headers', v_headers,
        'body', allgres_private.mcp_list_request(r.cursor),
        'allow_private', r.allow_private
      ));
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('count', v_n, 'calls', v_out);
END;
$fn$;

-- Stores one page of a server's tools. On the last page, tools the server no
-- longer lists are marked removed and their Functions switched off.
CREATE OR REPLACE FUNCTION allgres_public.fn_complete_mcp_probe(
  p_call_id uuid, p_status int, p_body text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  c allgres_private.mcp_probes%ROWTYPE;
  v_parsed jsonb;
  v_tool jsonb;
  v_name text;
  v_desc text;
  v_schema jsonb;
  v_hints jsonb;
  v_fp text;
  v_old allgres_private.mcp_tools%ROWTYPE;
  v_next text;
  v_err text;
  v_health text;
  v_count int := 0;
  v_changed int := 0;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  SELECT * INTO c FROM allgres_private.mcp_probes WHERE call_id = p_call_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_complete_mcp_probe: not found' USING ERRCODE = 'P0001';
  END IF;
  IF c.status <> 'in_flight' THEN
    RETURN jsonb_build_object('action', 'stale', 'reason', 'call_not_in_flight', 'status', c.status);
  END IF;

  IF c.purpose = 'ping' THEN
    v_health := CASE
      WHEN p_status IN (401, 403) THEN 'auth_needed'
      WHEN p_status IS NULL OR p_status < 100 OR p_status >= 500 THEN 'unreachable'
      ELSE 'ok' END;
    v_err := CASE
      WHEN p_status IS NULL OR p_status < 100 THEN left(COALESCE(NULLIF(p_body, ''), 'could not connect'), 500)
      WHEN p_status IN (401, 403) THEN format('the server answered HTTP %s: the key was missing or not accepted', p_status)
      WHEN p_status >= 500 THEN format('the server answered HTTP %s', p_status)
      ELSE format('answered HTTP %s', p_status) END;
    UPDATE allgres_private.mcp_probes
    SET status = 'harvested', response_status = p_status,
        error = CASE WHEN v_health = 'ok' THEN NULL ELSE v_err END, updated_at = now()
    WHERE call_id = p_call_id;
    UPDATE allgres_private.api_connections
    SET health = v_health, health_checked_at = now(), health_detail = v_err
    WHERE connection_id = c.connection_id;
    RETURN jsonb_build_object('action', CASE WHEN v_health = 'ok' THEN 'ok' ELSE 'error' END, 'health', v_health);
  END IF;

  IF p_status IS NULL OR p_status < 200 OR p_status >= 300 THEN
    v_err := left(COALESCE(NULLIF(p_body, ''), 'request failed'), 500);
    v_health := CASE WHEN p_status IN (401, 403) THEN 'auth_needed' ELSE 'unreachable' END;
  ELSE
    v_parsed := allgres_private.mcp_json_body(p_body);
    IF v_parsed IS NULL THEN
      v_err := 'the server did not answer with a JSON-RPC message';
      v_health := 'unreachable';
    ELSIF v_parsed ? 'error' THEN
      v_err := left('the server rejected tools/list: ' || COALESCE(v_parsed->'error'->>'message', 'unknown error'), 500);
      v_health := 'unreachable';
    ELSIF jsonb_typeof(v_parsed->'result'->'tools') <> 'array' THEN
      v_err := 'the server answered without a tools list';
      v_health := 'unreachable';
    END IF;
  END IF;

  IF v_err IS NOT NULL THEN
    UPDATE allgres_private.mcp_probes
    SET status = 'harvested', response_status = p_status, error = v_err, updated_at = now()
    WHERE call_id = p_call_id;
    UPDATE allgres_private.api_connections
    SET health = v_health, health_checked_at = now(), health_detail = v_err
    WHERE connection_id = c.connection_id;
    RETURN jsonb_build_object('action', 'error', 'health', v_health);
  END IF;

  FOR v_tool IN SELECT * FROM jsonb_array_elements(v_parsed->'result'->'tools') LOOP
    v_name := v_tool->>'name';
    IF v_name IS NULL OR btrim(v_name) = '' THEN
      CONTINUE;
    END IF;
    v_desc := left(COALESCE(v_tool->>'description', ''), 4000);
    v_schema := CASE WHEN jsonb_typeof(v_tool->'inputSchema') = 'object' THEN v_tool->'inputSchema' ELSE '{}'::jsonb END;
    v_hints := CASE WHEN jsonb_typeof(v_tool->'annotations') = 'object' THEN v_tool->'annotations' ELSE '{}'::jsonb END;
    v_fp := md5(v_name || E'\n' || v_desc || E'\n' || v_schema::text);
    v_count := v_count + 1;

    SELECT * INTO v_old FROM allgres_private.mcp_tools
    WHERE connection_id = c.connection_id AND tool_name = v_name;
    IF NOT FOUND THEN
      INSERT INTO allgres_private.mcp_tools
        (connection_id, tool_name, description, input_schema, server_hints, fingerprint,
         suggested_risk, status, last_seen_scan)
      VALUES (c.connection_id, v_name, v_desc, v_schema, v_hints, v_fp,
        allgres_private.mcp_suggest_risk(v_name, v_hints), 'new', c.scan_id);
    ELSIF v_old.fingerprint <> v_fp THEN
      UPDATE allgres_private.mcp_tools
      SET description = v_desc, input_schema = v_schema, server_hints = v_hints, fingerprint = v_fp,
          suggested_risk = allgres_private.mcp_suggest_risk(v_name, v_hints),
          status = CASE WHEN v_old.status IN ('registered', 'changed') THEN 'changed' ELSE 'new' END,
          last_seen_scan = c.scan_id, updated_at = now()
      WHERE connection_id = c.connection_id AND tool_name = v_name;
      IF v_old.status IN ('registered', 'changed') THEN
        v_changed := v_changed + 1;
        UPDATE allgres_private.functions SET is_active = false, updated_at = now()
        WHERE function_id = v_old.registered_function_id;
      END IF;
    ELSE
      -- A removed tool that came back unchanged is as it was; a Function
      -- that was switched off for it stays off until a person registers it.
      UPDATE allgres_private.mcp_tools
      SET last_seen_scan = c.scan_id,
          status = CASE WHEN v_old.status = 'removed'
                        THEN CASE WHEN v_old.registered_function_id IS NULL THEN 'new' ELSE 'changed' END
                        ELSE v_old.status END
      WHERE connection_id = c.connection_id AND tool_name = v_name;
    END IF;
  END LOOP;

  v_next := NULLIF(v_parsed->'result'->>'nextCursor', '');
  IF v_next IS NOT NULL THEN
    INSERT INTO allgres_private.mcp_probes (connection_id, scan_id, cursor, url, allow_private, status)
    VALUES (c.connection_id, c.scan_id, v_next, c.url, c.allow_private, 'queued');
  ELSE
    UPDATE allgres_private.functions SET is_active = false, updated_at = now()
    WHERE function_id IN (
      SELECT registered_function_id FROM allgres_private.mcp_tools
      WHERE connection_id = c.connection_id AND last_seen_scan IS DISTINCT FROM c.scan_id
        AND registered_function_id IS NOT NULL);
    UPDATE allgres_private.mcp_tools
    SET status = 'removed', updated_at = now()
    WHERE connection_id = c.connection_id AND last_seen_scan IS DISTINCT FROM c.scan_id
      AND status <> 'removed';
    UPDATE allgres_private.api_connections
    SET health = CASE WHEN EXISTS (
          SELECT 1 FROM allgres_private.mcp_tools
          WHERE connection_id = c.connection_id AND status = 'changed') THEN 'changed' ELSE 'ok' END,
        health_checked_at = now(),
        health_detail = CASE WHEN EXISTS (
          SELECT 1 FROM allgres_private.mcp_tools
          WHERE connection_id = c.connection_id AND status = 'changed')
          THEN 'a registered tool changed; register it again to switch it back on' END
    WHERE connection_id = c.connection_id;
  END IF;

  UPDATE allgres_private.mcp_probes
  SET status = 'harvested', response_status = p_status, updated_at = now()
  WHERE call_id = p_call_id;
  IF v_changed > 0 THEN
    PERFORM allgres_private.audit('mcp.tools_changed', jsonb_build_object(
      'connection_id', c.connection_id, 'changed', v_changed));
  END IF;
  RETURN jsonb_build_object('action', 'ok', 'tools', v_count, 'more', v_next IS NOT NULL);
END;
$fn$;

-- Creates an MCP server connection and starts its first discovery.
CREATE OR REPLACE FUNCTION allgres_public.fn_mcp_connect(
  p_name text, p_base_url text, p_auth_kind text DEFAULT 'none',
  p_api_key text DEFAULT NULL, p_allow_private_network boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_conn jsonb;
  v_id uuid;
  v_probe jsonb;
BEGIN
  v_conn := allgres_public.fn_create_connection(
    p_name, p_base_url, CASE WHEN p_auth_kind = 'oauth' THEN 'none' ELSE p_auth_kind END,
    CASE WHEN p_auth_kind = 'oauth' THEN NULL ELSE p_api_key END, p_allow_private_network, 0);
  v_id := (v_conn->>'connection_id')::uuid;
  UPDATE allgres_private.api_connections
  SET kind = 'mcp', auth_kind = CASE WHEN p_auth_kind = 'oauth' THEN 'oauth' ELSE auth_kind END
  WHERE connection_id = v_id;
  v_probe := allgres_public.fn_mcp_discover_start(v_id);
  PERFORM allgres_private.audit('mcp.connect', jsonb_build_object('connection_id', v_id, 'name', trim(p_name)));
  RETURN jsonb_build_object('ok', true, 'connection_id', v_id, 'call_id', v_probe->'call_id');
END;
$fn$;

-- Confirms a tool's risk level. Write and physical tools always need
-- approval; only a read tool may be left without one.
CREATE OR REPLACE FUNCTION allgres_public.fn_mcp_tool_set_risk(
  p_connection_id uuid, p_tool text, p_risk text, p_approval text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  t allgres_private.mcp_tools%ROWTYPE;
  v_approval text;
BEGIN
  IF p_risk NOT IN ('read', 'write', 'physical') THEN
    RAISE EXCEPTION 'risk must be read, write, or physical' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO t FROM allgres_private.mcp_tools
  WHERE connection_id = p_connection_id AND tool_name = p_tool FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tool not found' USING ERRCODE = 'P0001';
  END IF;
  v_approval := CASE
    WHEN p_risk <> 'read' THEN 'required'
    WHEN p_approval IN ('none', 'required') THEN p_approval
    ELSE 'none' END;
  UPDATE allgres_private.mcp_tools
  SET risk = p_risk, approval = v_approval, updated_at = now()
  WHERE connection_id = p_connection_id AND tool_name = p_tool;
  -- A registered Function follows its tool's approval setting at once.
  IF t.registered_function_id IS NOT NULL THEN
    UPDATE allgres_private.functions SET requires_approval = (v_approval = 'required'), updated_at = now()
    WHERE function_id = t.registered_function_id;
  END IF;
  PERFORM allgres_private.audit('mcp.tool_risk', jsonb_build_object(
    'connection_id', p_connection_id, 'tool', p_tool, 'risk', p_risk, 'approval', v_approval,
    'suggested', t.suggested_risk));
  RETURN jsonb_build_object('ok', true, 'risk', p_risk, 'approval', v_approval);
END;
$fn$;

-- Turns a confirmed tool into a Function agents can be given. Registering
-- again after a change re-approves the new description and schema.
CREATE OR REPLACE FUNCTION allgres_public.fn_mcp_tool_register(p_connection_id uuid, p_tool text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  t allgres_private.mcp_tools%ROWTYPE;
  c allgres_private.api_connections%ROWTYPE;
  v_name text;
  v_fn jsonb;
  v_id uuid;
  v_desc text;
  v_proc uuid;
  v_content text;
BEGIN
  SELECT * INTO t FROM allgres_private.mcp_tools
  WHERE connection_id = p_connection_id AND tool_name = p_tool FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tool not found' USING ERRCODE = 'P0001';
  END IF;
  IF t.status = 'removed' THEN
    RAISE EXCEPTION 'the server no longer lists this tool' USING ERRCODE = 'P0001';
  END IF;
  IF t.risk IS NULL THEN
    RAISE EXCEPTION 'confirm the risk level of this tool first' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO c FROM allgres_private.api_connections WHERE connection_id = p_connection_id;
  v_desc := COALESCE(NULLIF(btrim(t.description), ''), 'MCP tool ' || t.tool_name || ' on ' || c.name);

  IF t.registered_function_id IS NOT NULL THEN
    v_id := t.registered_function_id;
    UPDATE allgres_private.functions
    SET description = left(v_desc, 1000), param_schema = t.input_schema,
        is_active = true, requires_approval = (t.approval = 'required'), updated_at = now()
    WHERE function_id = v_id;
  ELSE
    v_name := lower(regexp_replace(c.name || '_' || t.tool_name, '[^a-zA-Z0-9]+', '_', 'g'));
    v_name := regexp_replace(v_name, '^[^a-z]+', '');
    IF v_name = '' THEN v_name := 'mcp_tool'; END IF;
    v_name := left(v_name, 54);
    IF EXISTS (SELECT 1 FROM allgres_private.functions WHERE name = v_name) THEN
      v_name := left(v_name, 45) || '_' || left(md5(p_connection_id::text || t.tool_name), 8);
    END IF;
    v_fn := allgres_public.fn_create_function(
      v_name, left(v_desc, 1000), 'mcp_call',
      jsonb_build_object('tool', t.tool_name), NULL, t.input_schema, NULL, p_connection_id);
    v_id := (v_fn->>'function_id')::uuid;
    UPDATE allgres_private.functions SET requires_approval = (t.approval = 'required')
    WHERE function_id = v_id;
  END IF;
  v_proc := t.registered_procedure_id;
  v_content := format(E'%s\n\nThis calls the tool "%s" on the MCP server "%s". Call the function "%s" with the arguments the tool expects (schema: %s).',
    v_desc, t.tool_name, c.name, (SELECT name FROM allgres_private.functions WHERE function_id = v_id), t.input_schema::text);
  IF v_proc IS NULL THEN
    v_name := (SELECT name FROM allgres_private.functions WHERE function_id = v_id);
    IF EXISTS (SELECT 1 FROM allgres_private.procedures WHERE name = v_name) THEN
      v_name := left(v_name, 45) || '_' || left(md5(v_id::text), 8);
    END IF;
    v_proc := (allgres_public.fn_create_procedure(v_name, v_content)->>'procedure_id')::uuid;
    PERFORM allgres_public.fn_bind_procedure_function(v_proc, v_id);
  ELSE
    UPDATE allgres_private.procedures SET content = v_content, is_active = true, updated_at = now()
    WHERE procedure_id = v_proc;
  END IF;
  UPDATE allgres_private.mcp_tools
  SET status = 'registered', registered_function_id = v_id, registered_procedure_id = v_proc, updated_at = now()
  WHERE connection_id = p_connection_id AND tool_name = p_tool;
  UPDATE allgres_private.api_connections
  SET health = CASE WHEN health = 'changed' AND NOT EXISTS (
        SELECT 1 FROM allgres_private.mcp_tools m
        WHERE m.connection_id = p_connection_id AND m.status = 'changed') THEN 'ok' ELSE health END
  WHERE connection_id = p_connection_id;
  PERFORM allgres_private.audit('mcp.tool_register', jsonb_build_object(
    'connection_id', p_connection_id, 'tool', p_tool, 'function_id', v_id, 'risk', t.risk));
  RETURN jsonb_build_object('ok', true, 'function_id', v_id, 'procedure_id', v_proc);
END;
$fn$;

-- The "Test connection" button of a plain HTTP API connection: one GET to its
-- base address with its credential. Any answer below 500 other than 401/403
-- counts as reachable (many APIs answer 404 at their root). An MCP server
-- gets a full discovery instead.
CREATE OR REPLACE FUNCTION allgres_public.fn_connection_test_start(p_connection_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  c allgres_private.api_connections%ROWTYPE;
  v_reason text;
  v_call uuid;
BEGIN
  SELECT * INTO c FROM allgres_private.api_connections WHERE connection_id = p_connection_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'connection not found' USING ERRCODE = 'P0001';
  END IF;
  IF c.kind = 'mcp' THEN
    RETURN allgres_public.fn_mcp_discover_start(p_connection_id);
  END IF;
  v_reason := allgres_private.check_outbound_url(c.base_url, c.allow_private_network);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'connection endpoint rejected: %', v_reason USING ERRCODE = 'P0001';
  END IF;
  UPDATE allgres_private.mcp_probes
  SET status = 'lost', error = 'superseded by a newer test', updated_at = now()
  WHERE connection_id = p_connection_id AND status IN ('queued', 'in_flight');
  INSERT INTO allgres_private.mcp_probes (connection_id, scan_id, purpose, url, allow_private, status)
  VALUES (p_connection_id, gen_random_uuid(), 'ping', c.base_url, c.allow_private_network, 'queued')
  RETURNING call_id INTO v_call;
  RETURN jsonb_build_object('ok', true, 'call_id', v_call, 'connection_id', p_connection_id);
END;
$fn$;

-- Models a provider lists that have no price yet, who uses them, and what the
-- provider itself says they cost. A model nobody priced cannot count toward
-- a budget, so the dashboard keeps asking.
CREATE OR REPLACE FUNCTION allgres_public.fn_unpriced_models()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT COALESCE(jsonb_agg(row ORDER BY (jsonb_array_length(row->'agents') = 0), row->>'provider', row->>'model'), '[]'::jsonb)
  FROM (
    SELECT jsonb_build_object(
      'provider_id', p.provider_id, 'provider', p.name, 'model', m.model,
      'reported', p.reported_prices -> m.model,
      'agents', COALESCE((
        SELECT jsonb_agg(a.name ORDER BY a.name)
        FROM allgres_private.policies po JOIN allgres_private.agents a USING (agent_id)
        WHERE a.is_active AND NOT a.is_system AND a.name NOT LIKE 'selftest%'
          AND po.llm_config->>'provider' = p.name AND po.llm_config->>'model' = m.model), '[]'::jsonb)) AS row
    FROM allgres_private.llm_providers p
    CROSS JOIN LATERAL (
      SELECT DISTINCT model FROM (
        SELECT jsonb_array_elements_text(COALESCE(p.available_models, '[]'::jsonb)) AS model
        UNION
        SELECT po.llm_config->>'model' FROM allgres_private.policies po
        WHERE po.llm_config->>'provider' = p.name AND NULLIF(po.llm_config->>'model', '') IS NOT NULL) u
    ) m
    WHERE p.is_enabled AND p.purpose = 'chat'
      AND NOT EXISTS (SELECT 1 FROM allgres_private.llm_model_prices mp
                      WHERE mp.provider_id = p.provider_id AND mp.model = m.model)
  ) t
$fn$;

-- Takes the price a provider reported for one model, or for every model it
-- reported when p_model is NULL, as the price to count spend with.
CREATE OR REPLACE FUNCTION allgres_public.fn_apply_reported_prices(p_provider_id uuid, p_model text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  p allgres_private.llm_providers%ROWTYPE;
  r record;
  n int := 0;
BEGIN
  SELECT * INTO p FROM allgres_private.llm_providers WHERE provider_id = p_provider_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'provider not found' USING ERRCODE = 'P0001';
  END IF;
  FOR r IN SELECT key AS model, value FROM jsonb_each(p.reported_prices)
           WHERE p_model IS NULL OR key = p_model LOOP
    PERFORM allgres_public.fn_set_model_price(p_provider_id, r.model,
      (r.value->>'input_per_1k')::numeric, (r.value->>'output_per_1k')::numeric);
    n := n + 1;
  END LOOP;
  IF p_model IS NOT NULL AND n = 0 THEN
    RAISE EXCEPTION 'this provider did not report a price for that model' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('ok', true, 'applied', n);
END;
$fn$;
