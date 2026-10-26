-- Signing in to an MCP server with OAuth (docs/stage3-design.md, slice 3b).
--
-- Allgres is a public OAuth client: authorization code with PKCE (S256), the
-- `resource` indicator, and a check of the `iss` the server returns. Nothing
-- here talks to the network. The runtime worker does the three kinds of
-- request (finding the server's sign-in, registering a client, exchanging a
-- code or a refresh token) and hands the answer to fn_complete_mcp_oauth.
--
-- How a person sees it: press Sign in on an MCP server; Allgres finds the
-- server's authorization server, gets a client id, and sends the browser
-- there; the browser returns to /oauth/callback; Allgres swaps the code for a
-- token and looks for tools. Tokens are stored encrypted like every other
-- secret and are refreshed before they expire.
--
-- Client id, in order: one the person typed; a Client ID Metadata Document
-- (Allgres serves it at /oauth/client.json when it is reached over https and
-- the authorization server supports it); Dynamic Client Registration.
--
-- Loaded after sql/mcp_connections.sql and before sql/selftest.sql
-- (src/lib.rs).

ALTER TABLE allgres_private.api_connections
  DROP CONSTRAINT IF EXISTS api_connections_auth_kind_check;
ALTER TABLE allgres_private.api_connections
  ADD CONSTRAINT api_connections_auth_kind_check
  CHECK (auth_kind IN ('none', 'authorization', 'x-api-key', 'oauth'));

-- The header an auth_kind is sent in. An OAuth token travels exactly like a
-- bearer key, so everything downstream (outbound_calls, the execution gate)
-- keeps seeing 'authorization'.
CREATE OR REPLACE FUNCTION allgres_private.conn_header_kind(p_auth_kind text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE p_auth_kind WHEN 'none' THEN NULL WHEN 'oauth' THEN 'authorization' ELSE p_auth_kind END
$fn$;

CREATE TABLE IF NOT EXISTS allgres_private.mcp_oauth_config (
  connection_id          uuid PRIMARY KEY REFERENCES allgres_private.api_connections(connection_id) ON DELETE CASCADE,
  resource               text,
  issuer                 text,
  authorization_endpoint text,
  token_endpoint         text,
  registration_endpoint  text,
  cimd_supported         boolean NOT NULL DEFAULT false,
  iss_supported          boolean NOT NULL DEFAULT false,
  scopes_supported       jsonb NOT NULL DEFAULT '[]'::jsonb,
  scope                  text,
  client_id              text,
  client_source          text CHECK (client_source IN ('manual', 'cimd', 'dcr')),
  -- The address the client id and redirect address were made for. A client
  -- registered for one address is not reused from another.
  client_origin          text,
  discovered_at          timestamptz
);

CREATE TABLE IF NOT EXISTS allgres_private.mcp_oauth_flows (
  flow_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id  uuid NOT NULL REFERENCES allgres_private.api_connections(connection_id) ON DELETE CASCADE,
  state          text NOT NULL UNIQUE,
  code_verifier  text NOT NULL,
  redirect_uri   text NOT NULL,
  code           text,
  status         text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'exchanging', 'done', 'failed')),
  error          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL DEFAULT now() + interval '10 minutes'
);

CREATE TABLE IF NOT EXISTS allgres_private.mcp_oauth_tokens (
  connection_id  uuid PRIMARY KEY REFERENCES allgres_private.api_connections(connection_id) ON DELETE CASCADE,
  access_token   text NOT NULL,
  refresh_token  text,
  expires_at     timestamptz,
  scope          text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS allgres_private.mcp_oauth_jobs (
  call_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id    uuid NOT NULL REFERENCES allgres_private.api_connections(connection_id) ON DELETE CASCADE,
  flow_id          uuid REFERENCES allgres_private.mcp_oauth_flows(flow_id) ON DELETE CASCADE,
  kind             text NOT NULL CHECK (kind IN ('discover', 'register', 'exchange', 'refresh')),
  status           text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'in_flight', 'harvested', 'lost')),
  response_status  int,
  error            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS mcp_oauth_jobs_ready_idx
  ON allgres_private.mcp_oauth_jobs (created_at) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS mcp_oauth_jobs_inflight_idx
  ON allgres_private.mcp_oauth_jobs (updated_at) WHERE status = 'in_flight';

-- An OAuth connection's key is its current access token.
CREATE OR REPLACE FUNCTION allgres_private.connection_secret(p_connection_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM allgres_private.api_connections
             WHERE connection_id = p_connection_id AND auth_kind = 'oauth') THEN
    RETURN (SELECT allgres_private.decrypt_secret(access_token)
            FROM allgres_private.mcp_oauth_tokens WHERE connection_id = p_connection_id);
  END IF;
  RETURN (SELECT allgres_private.decrypt_secret(api_key)
          FROM allgres_private.api_connection_secrets WHERE connection_id = p_connection_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.mcp_oauth_job_pending(p_connection_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $fn$
  SELECT EXISTS (SELECT 1 FROM allgres_private.mcp_oauth_jobs
                 WHERE connection_id = p_connection_id AND status IN ('queued', 'in_flight')
                   AND kind IN ('discover', 'register'))
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.mcp_oauth_queue(p_connection_id uuid, p_kind text, p_flow uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_call uuid;
BEGIN
  INSERT INTO allgres_private.mcp_oauth_jobs (connection_id, flow_id, kind)
  VALUES (p_connection_id, p_flow, p_kind) RETURNING call_id INTO v_call;
  RETURN v_call;
END;
$fn$;

-- Where the browser returns to, and how an https address makes a client id.
CREATE OR REPLACE FUNCTION allgres_private.mcp_oauth_base_ok(p_base text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT p_base ~* '^https://[^/?#]+$'
      OR p_base ~* '^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?$'
$fn$;

-- Starts or continues a sign-in. Call it again while it answers
-- 'discovering' or 'registering'; when it answers 'ready' it carries the
-- address to send the browser to.
CREATE OR REPLACE FUNCTION allgres_public.fn_mcp_oauth_start(
  p_connection_id uuid, p_redirect_base text, p_client_id text DEFAULT NULL, p_scope text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  c allgres_private.api_connections%ROWTYPE;
  k allgres_private.mcp_oauth_config%ROWTYPE;
  v_base text := rtrim(COALESCE(p_redirect_base, ''), '/');
  v_verifier text;
  v_state text;
  v_flow uuid;
  v_scope text;
  v_url text;
BEGIN
  SELECT * INTO c FROM allgres_private.api_connections WHERE connection_id = p_connection_id;
  IF NOT FOUND OR c.kind <> 'mcp' THEN
    RAISE EXCEPTION 'MCP server not found' USING ERRCODE = 'P0001';
  END IF;
  IF c.auth_kind <> 'oauth' THEN
    RAISE EXCEPTION 'this server is not set up to sign in with OAuth' USING ERRCODE = 'P0001';
  END IF;
  IF NOT allgres_private.mcp_oauth_base_ok(v_base) THEN
    RAISE EXCEPTION 'sign in from an https address, or from localhost' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO allgres_private.mcp_oauth_config (connection_id) VALUES (p_connection_id)
  ON CONFLICT DO NOTHING;
  IF NULLIF(btrim(p_client_id), '') IS NOT NULL THEN
    UPDATE allgres_private.mcp_oauth_config
    SET client_id = btrim(p_client_id), client_source = 'manual', client_origin = v_base
    WHERE connection_id = p_connection_id;
  END IF;
  IF p_scope IS NOT NULL THEN
    UPDATE allgres_private.mcp_oauth_config SET scope = NULLIF(btrim(p_scope), '')
    WHERE connection_id = p_connection_id;
  END IF;
  SELECT * INTO k FROM allgres_private.mcp_oauth_config WHERE connection_id = p_connection_id;

  IF allgres_private.mcp_oauth_job_pending(p_connection_id) THEN
    RETURN jsonb_build_object('ok', true, 'status',
      CASE WHEN k.authorization_endpoint IS NULL THEN 'discovering' ELSE 'registering' END);
  END IF;

  IF k.authorization_endpoint IS NULL OR k.token_endpoint IS NULL THEN
    PERFORM allgres_private.mcp_oauth_queue(p_connection_id, 'discover');
    RETURN jsonb_build_object('ok', true, 'status', 'discovering');
  END IF;

  IF k.client_id IS NULL OR k.client_origin IS DISTINCT FROM v_base THEN
    IF k.client_source = 'manual' AND k.client_origin IS DISTINCT FROM v_base THEN
      NULL; -- a typed client id is kept for any address
    ELSIF k.cimd_supported AND v_base ~* '^https://' THEN
      UPDATE allgres_private.mcp_oauth_config
      SET client_id = v_base || '/oauth/client.json', client_source = 'cimd', client_origin = v_base
      WHERE connection_id = p_connection_id;
    ELSIF k.registration_endpoint IS NOT NULL THEN
      UPDATE allgres_private.mcp_oauth_config SET client_origin = v_base WHERE connection_id = p_connection_id;
      PERFORM allgres_private.mcp_oauth_queue(p_connection_id, 'register');
      RETURN jsonb_build_object('ok', true, 'status', 'registering');
    ELSE
      RETURN jsonb_build_object('ok', true, 'status', 'needs_client_id',
        'message', 'This server''s sign-in does not register clients on its own. Enter the client id its owner gave you.');
    END IF;
    SELECT * INTO k FROM allgres_private.mcp_oauth_config WHERE connection_id = p_connection_id;
  END IF;

  v_verifier := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_state := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  INSERT INTO allgres_private.mcp_oauth_flows (connection_id, state, code_verifier, redirect_uri)
  VALUES (p_connection_id, v_state, allgres_private.encrypt_secret(v_verifier), v_base || '/oauth/callback')
  RETURNING flow_id INTO v_flow;

  v_scope := COALESCE(k.scope,
    CASE WHEN jsonb_array_length(k.scopes_supported) > 0
         THEN (SELECT string_agg(s, ' ') FROM jsonb_array_elements_text(k.scopes_supported) s) END);
  v_url := k.authorization_endpoint
    || CASE WHEN position('?' IN k.authorization_endpoint) > 0 THEN '&' ELSE '?' END
    || 'response_type=code'
    || '&client_id=' || allgres_private.url_encode(k.client_id)
    || '&redirect_uri=' || allgres_private.url_encode(v_base || '/oauth/callback')
    || '&state=' || v_state
    || '&code_challenge=' || translate(encode(sha256(convert_to(v_verifier, 'UTF8')), 'base64'), '+/=', '-_')
    || '&code_challenge_method=S256'
    || '&resource=' || allgres_private.url_encode(COALESCE(k.resource, c.base_url))
    || CASE WHEN v_scope IS NOT NULL THEN '&scope=' || allgres_private.url_encode(v_scope) ELSE '' END;
  PERFORM allgres_private.audit('mcp.oauth_start', jsonb_build_object(
    'connection_id', p_connection_id, 'client_source', k.client_source));
  RETURN jsonb_build_object('ok', true, 'status', 'ready', 'authorize_url', v_url, 'flow_id', v_flow);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.url_encode(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT COALESCE(string_agg(
    CASE WHEN b ~ '^[A-Za-z0-9._~-]$' THEN b
         ELSE upper(regexp_replace(encode(convert_to(b, 'UTF8'), 'hex'), '(..)', '%\1', 'g')) END, ''), '')
  FROM regexp_split_to_table(COALESCE(p_text, ''), '') AS b
$fn$;

-- The browser comes back here with a code. No session is needed: the state
-- is a one-time secret only the signed-in admin's flow knows.
CREATE OR REPLACE FUNCTION allgres_public.fn_mcp_oauth_callback(
  p_state text, p_code text, p_iss text, p_error text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  f allgres_private.mcp_oauth_flows%ROWTYPE;
  k allgres_private.mcp_oauth_config%ROWTYPE;
  v_err text;
BEGIN
  SELECT * INTO f FROM allgres_private.mcp_oauth_flows
  WHERE state = p_state AND status = 'pending' AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'This sign-in link is not valid any more. Start again from the MCP servers page.');
  END IF;
  SELECT * INTO k FROM allgres_private.mcp_oauth_config WHERE connection_id = f.connection_id;

  IF NULLIF(p_error, '') IS NOT NULL THEN
    v_err := 'the server refused the sign-in: ' || left(p_error, 200);
  ELSIF NULLIF(p_code, '') IS NULL THEN
    v_err := 'the server sent no code';
  ELSIF NULLIF(p_iss, '') IS NOT NULL AND k.issuer IS NOT NULL AND p_iss <> k.issuer THEN
    v_err := 'the answer came from a different server than the one asked (issuer mismatch)';
  ELSIF NULLIF(p_iss, '') IS NULL AND k.iss_supported THEN
    v_err := 'the server did not say who answered (missing issuer)';
  END IF;

  IF v_err IS NOT NULL THEN
    UPDATE allgres_private.mcp_oauth_flows SET status = 'failed', error = v_err WHERE flow_id = f.flow_id;
    UPDATE allgres_private.api_connections
    SET health = 'auth_needed', health_checked_at = now(), health_detail = v_err
    WHERE connection_id = f.connection_id;
    RETURN jsonb_build_object('ok', false, 'error', v_err);
  END IF;

  UPDATE allgres_private.mcp_oauth_flows
  SET status = 'exchanging', code = allgres_private.encrypt_secret(p_code) WHERE flow_id = f.flow_id;
  PERFORM allgres_private.mcp_oauth_queue(f.connection_id, 'exchange', f.flow_id);
  RETURN jsonb_build_object('ok', true, 'connection_id', f.connection_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_claim_mcp_oauth(p_limit int DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  v_out jsonb := '[]'::jsonb;
  v_n int := 0;
  v_call jsonb;
  c allgres_private.api_connections%ROWTYPE;
  k allgres_private.mcp_oauth_config%ROWTYPE;
  f allgres_private.mcp_oauth_flows%ROWTYPE;
  t allgres_private.mcp_oauth_tokens%ROWTYPE;
  v_base text;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  FOR r IN
    SELECT * FROM allgres_private.mcp_oauth_jobs
    WHERE status = 'queued'
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 4), 16))
  LOOP
    SELECT * INTO c FROM allgres_private.api_connections WHERE connection_id = r.connection_id;
    SELECT * INTO k FROM allgres_private.mcp_oauth_config WHERE connection_id = r.connection_id;
    v_call := NULL;

    IF r.kind = 'discover' THEN
      v_call := jsonb_build_object('kind', 'mcp_oauth_discover', 'url', c.base_url,
        'headers', '{}'::jsonb, 'body', '{}'::jsonb);
    ELSIF r.kind = 'register' AND k.registration_endpoint IS NOT NULL THEN
      v_base := k.client_origin;
      v_call := jsonb_build_object('kind', 'llm', 'url', k.registration_endpoint,
        'headers', jsonb_build_object('accept', 'application/json', 'content-type', 'application/json'),
        'body', jsonb_build_object(
          'client_name', 'Allgres',
          'redirect_uris', jsonb_build_array(v_base || '/oauth/callback'),
          'grant_types', jsonb_build_array('authorization_code', 'refresh_token'),
          'response_types', jsonb_build_array('code'),
          'token_endpoint_auth_method', 'none',
          'application_type', CASE WHEN v_base ~* '^https://' THEN 'web' ELSE 'native' END));
    ELSIF r.kind = 'exchange' THEN
      SELECT * INTO f FROM allgres_private.mcp_oauth_flows WHERE flow_id = r.flow_id;
      IF f.flow_id IS NOT NULL AND k.token_endpoint IS NOT NULL THEN
        v_call := jsonb_build_object('kind', 'oauth', 'url', k.token_endpoint,
          'headers', jsonb_build_object('accept', 'application/json'),
          'body', jsonb_strip_nulls(jsonb_build_object(
            'grant_type', 'authorization_code',
            'code', allgres_private.decrypt_secret(f.code),
            'redirect_uri', f.redirect_uri,
            'client_id', k.client_id,
            'code_verifier', allgres_private.decrypt_secret(f.code_verifier),
            'resource', COALESCE(k.resource, c.base_url))));
      END IF;
    ELSIF r.kind = 'refresh' THEN
      SELECT * INTO t FROM allgres_private.mcp_oauth_tokens WHERE connection_id = r.connection_id;
      IF t.refresh_token IS NOT NULL AND k.token_endpoint IS NOT NULL THEN
        v_call := jsonb_build_object('kind', 'oauth', 'url', k.token_endpoint,
          'headers', jsonb_build_object('accept', 'application/json'),
          'body', jsonb_strip_nulls(jsonb_build_object(
            'grant_type', 'refresh_token',
            'refresh_token', allgres_private.decrypt_secret(t.refresh_token),
            'client_id', k.client_id,
            'resource', COALESCE(k.resource, c.base_url))));
      END IF;
    END IF;

    IF v_call IS NULL OR NOT c.is_enabled THEN
      UPDATE allgres_private.mcp_oauth_jobs
      SET status = 'lost', error = 'nothing to send', updated_at = now() WHERE call_id = r.call_id;
      CONTINUE;
    END IF;
    UPDATE allgres_private.mcp_oauth_jobs SET status = 'in_flight', updated_at = now() WHERE call_id = r.call_id;
    v_out := v_out || jsonb_build_array(v_call || jsonb_build_object(
      'call_id', r.call_id, 'method', 'POST', 'allow_private', c.allow_private_network));
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('count', v_n, 'calls', v_out);
END;
$fn$;

-- Takes what the worker got back. 'discover' answers with what the server
-- says about its sign-in; 'register' with a client id; 'exchange' and
-- 'refresh' with tokens.
CREATE OR REPLACE FUNCTION allgres_public.fn_complete_mcp_oauth(p_call_id uuid, p_status int, p_body text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  j allgres_private.mcp_oauth_jobs%ROWTYPE;
  c allgres_private.api_connections%ROWTYPE;
  k allgres_private.mcp_oauth_config%ROWTYPE;
  v jsonb;
  v_err text;
  v_reason text;
  v_expires timestamptz;
  v_access text;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  SELECT * INTO j FROM allgres_private.mcp_oauth_jobs WHERE call_id = p_call_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_complete_mcp_oauth: not found' USING ERRCODE = 'P0001';
  END IF;
  IF j.status <> 'in_flight' THEN
    RETURN jsonb_build_object('action', 'stale', 'status', j.status);
  END IF;
  SELECT * INTO c FROM allgres_private.api_connections WHERE connection_id = j.connection_id;
  SELECT * INTO k FROM allgres_private.mcp_oauth_config WHERE connection_id = j.connection_id;

  BEGIN
    v := p_body::jsonb;
  EXCEPTION WHEN others THEN
    v := NULL;
  END;

  IF p_status IS NULL OR p_status < 200 OR p_status >= 300 OR v IS NULL OR jsonb_typeof(v) <> 'object' THEN
    v_err := left(COALESCE(
      CASE WHEN jsonb_typeof(v) = 'object' THEN COALESCE(v->>'error_description', v->>'error', v->>'message') END,
      NULLIF(p_body, ''), 'request failed'), 500);
  ELSIF v ? 'error' AND j.kind <> 'discover' THEN
    v_err := left(COALESCE(v->>'error_description', v->>'error'), 500);
  END IF;

  IF v_err IS NULL THEN
    IF j.kind = 'discover' THEN
      v_reason := allgres_private.check_outbound_url(v->>'token_endpoint', c.allow_private_network);
      IF v_reason IS NULL AND NULLIF(v->>'registration_endpoint', '') IS NOT NULL THEN
        v_reason := allgres_private.check_outbound_url(v->>'registration_endpoint', c.allow_private_network);
      END IF;
      IF v_reason IS NOT NULL THEN
        v_err := 'the server''s sign-in address was rejected: ' || v_reason;
      ELSE
        UPDATE allgres_private.mcp_oauth_config
        SET resource = v->>'resource', issuer = v->>'issuer',
            authorization_endpoint = v->>'authorization_endpoint', token_endpoint = v->>'token_endpoint',
            registration_endpoint = NULLIF(v->>'registration_endpoint', ''),
            cimd_supported = COALESCE((v->>'cimd_supported')::boolean, false),
            iss_supported = COALESCE((v->>'iss_supported')::boolean, false),
            scopes_supported = CASE WHEN jsonb_typeof(v->'scopes_supported') = 'array' THEN v->'scopes_supported' ELSE '[]'::jsonb END,
            discovered_at = now()
        WHERE connection_id = j.connection_id;
      END IF;
    ELSIF j.kind = 'register' THEN
      IF NULLIF(v->>'client_id', '') IS NULL THEN
        v_err := 'the server did not return a client id';
      ELSE
        UPDATE allgres_private.mcp_oauth_config
        SET client_id = v->>'client_id', client_source = 'dcr'
        WHERE connection_id = j.connection_id;
      END IF;
    ELSE
      v_access := NULLIF(v->>'access_token', '');
      IF v_access IS NULL THEN
        v_err := 'the server did not return an access token';
      ELSE
        v_expires := CASE WHEN (v->>'expires_in') ~ '^[0-9]+$' THEN now() + make_interval(secs => (v->>'expires_in')::int) END;
        INSERT INTO allgres_private.mcp_oauth_tokens (connection_id, access_token, refresh_token, expires_at, scope)
        VALUES (j.connection_id, allgres_private.encrypt_secret(v_access),
                allgres_private.encrypt_secret(NULLIF(v->>'refresh_token', '')), v_expires, v->>'scope')
        ON CONFLICT (connection_id) DO UPDATE
        SET access_token = EXCLUDED.access_token,
            -- A refresh answer may leave out a new refresh token; keep the old one.
            refresh_token = COALESCE(EXCLUDED.refresh_token, mcp_oauth_tokens.refresh_token),
            expires_at = EXCLUDED.expires_at, scope = COALESCE(EXCLUDED.scope, mcp_oauth_tokens.scope),
            updated_at = now();
      END IF;
    END IF;
  END IF;

  UPDATE allgres_private.mcp_oauth_jobs
  SET status = 'harvested', response_status = p_status, error = v_err, updated_at = now()
  WHERE call_id = p_call_id;

  IF v_err IS NOT NULL THEN
    IF j.flow_id IS NOT NULL THEN
      UPDATE allgres_private.mcp_oauth_flows SET status = 'failed', error = v_err, code = NULL WHERE flow_id = j.flow_id;
    END IF;
    UPDATE allgres_private.api_connections
    SET health = 'auth_needed', health_checked_at = now(),
        health_detail = CASE j.kind
          WHEN 'refresh' THEN 'your sign-in expired and could not be renewed: ' || v_err
          ELSE 'sign-in failed: ' || v_err END
    WHERE connection_id = j.connection_id;
    RETURN jsonb_build_object('action', 'error', 'kind', j.kind);
  END IF;

  IF j.kind IN ('exchange', 'refresh') THEN
    IF j.flow_id IS NOT NULL THEN
      UPDATE allgres_private.mcp_oauth_flows SET status = 'done', code = NULL WHERE flow_id = j.flow_id;
    END IF;
    PERFORM allgres_private.audit('mcp.oauth_' || j.kind, jsonb_build_object('connection_id', j.connection_id));
    -- Signed in (or renewed): look for tools, which also sets health.
    PERFORM allgres_public.fn_mcp_discover_start(j.connection_id);
  END IF;
  RETURN jsonb_build_object('action', 'ok', 'kind', j.kind);
END;
$fn$;

-- Queues a refresh for each token that runs out soon and has a refresh token.
-- The worker calls this on its regular tick through fn_watchdog.
CREATE OR REPLACE FUNCTION allgres_private.mcp_oauth_refresh_due()
RETURNS int
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT t.connection_id FROM allgres_private.mcp_oauth_tokens t
    JOIN allgres_private.api_connections c ON c.connection_id = t.connection_id
    WHERE t.refresh_token IS NOT NULL AND c.is_enabled AND t.expires_at < now() + interval '5 minutes'
      AND NOT EXISTS (SELECT 1 FROM allgres_private.mcp_oauth_jobs j
                      WHERE j.connection_id = t.connection_id AND j.kind = 'refresh'
                        AND (j.status IN ('queued', 'in_flight')
                             OR (j.status = 'harvested' AND j.error IS NOT NULL AND j.updated_at > now() - interval '10 minutes')))
  LOOP
    PERFORM allgres_private.mcp_oauth_queue(r.connection_id, 'refresh');
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$fn$;

-- Forgets the sign-in: tokens and the client registration are removed.
CREATE OR REPLACE FUNCTION allgres_public.fn_mcp_oauth_forget(p_connection_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.mcp_oauth_tokens WHERE connection_id = p_connection_id;
  UPDATE allgres_private.mcp_oauth_config
  SET client_id = CASE WHEN client_source = 'manual' THEN client_id END,
      client_source = CASE WHEN client_source = 'manual' THEN 'manual' END,
      client_origin = CASE WHEN client_source = 'manual' THEN client_origin END
  WHERE connection_id = p_connection_id;
  UPDATE allgres_private.api_connections
  SET health = 'auth_needed', health_checked_at = now(), health_detail = 'signed out'
  WHERE connection_id = p_connection_id AND auth_kind = 'oauth';
  PERFORM allgres_private.audit('mcp.oauth_forget', jsonb_build_object('connection_id', p_connection_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;
