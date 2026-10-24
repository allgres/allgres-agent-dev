\set ON_ERROR_STOP on
-- Structural checks on the restored database for
-- scripts/run_dump_restore_test.sh. pg_restore --disable-triggers also skips
-- foreign-key checks, so every FK in allgres_private is checked here.
DO $block$
DECLARE
  c record;
  v_sql text;
  v_n bigint;
  v_bad text[] := '{}';
  v_checked int := 0;
BEGIN
  FOR c IN
    SELECT con.conname, con.conrelid::regclass AS child, con.confrelid::regclass AS parent,
           array_agg(ca.attname ORDER BY k.ord) AS child_cols,
           array_agg(pa.attname ORDER BY k.ord) AS parent_cols
    FROM pg_constraint con
    JOIN pg_namespace n ON n.oid = con.connamespace AND n.nspname = 'allgres_private'
    CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(ck, pk, ord)
    JOIN pg_attribute ca ON ca.attrelid = con.conrelid AND ca.attnum = k.ck
    JOIN pg_attribute pa ON pa.attrelid = con.confrelid AND pa.attnum = k.pk
    WHERE con.contype = 'f'
    GROUP BY con.oid, con.conname, con.conrelid, con.confrelid
  LOOP
    v_sql := format('SELECT count(*) FROM %s c WHERE %s AND NOT EXISTS (SELECT 1 FROM %s p WHERE %s)',
      c.child,
      (SELECT string_agg(format('c.%I IS NOT NULL', col), ' AND ') FROM unnest(c.child_cols) col),
      c.parent,
      (SELECT string_agg(format('p.%I = c.%I', pc, cc), ' AND ')
       FROM unnest(c.parent_cols, c.child_cols) AS u(pc, cc)));
    EXECUTE v_sql INTO v_n;
    v_checked := v_checked + 1;
    IF v_n > 0 THEN
      v_bad := v_bad || format('%s (%s -> %s): %s', c.conname, c.child, c.parent, v_n);
    END IF;
  END LOOP;
  IF cardinality(v_bad) > 0 THEN
    RAISE EXCEPTION 'dump/restore verify: orphan foreign keys: %', v_bad;
  END IF;
  RAISE NOTICE 'dump/restore verify: % foreign keys checked, no orphans', v_checked;
END
$block$;

-- Fixture rows that only exist because of the dump-coverage registrations.
DO $block$
DECLARE
  v_missing text[] := '{}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users WHERE username = 'dr_user') THEN v_missing := v_missing || 'users'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.user_agent_assignments ua JOIN allgres_private.agents a USING (agent_id) WHERE a.name = 'dr_chat_agent') THEN v_missing := v_missing || 'user_agent_assignments'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.user_agent_preferences) THEN v_missing := v_missing || 'user_agent_preferences'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.user_agent_chat_sessions) THEN v_missing := v_missing || 'user_agent_chat_sessions'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.channel_messages WHERE content = 'dump/restore fixture message') THEN v_missing := v_missing || 'channel_messages'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.fix_proposals WHERE reason = 'dump/restore fixture') THEN v_missing := v_missing || 'fix_proposals'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.function_history h JOIN allgres_private.functions f USING (function_id) WHERE f.name = 'dr_user_fn') THEN v_missing := v_missing || 'function_history'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.user_project_chat_sessions) THEN v_missing := v_missing || 'user_project_chat_sessions'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.function_calls WHERE result = '{"fixture": true}'::jsonb) THEN v_missing := v_missing || 'function_calls'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.procedure_calls WHERE result = '{"fixture": true}'::jsonb) THEN v_missing := v_missing || 'procedure_calls'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agent_groups WHERE name = 'dr team') THEN v_missing := v_missing || 'agent_groups'::text; END IF;
  IF (SELECT count(*) FROM allgres_private.agent_group_members m JOIN allgres_private.agent_groups g USING (group_id) WHERE g.name = 'dr team') <> 2 THEN v_missing := v_missing || 'agent_group_members'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.canvas_positions p JOIN allgres_private.agents a ON a.agent_id = p.item_id WHERE a.name = 'dr_chat_agent') THEN v_missing := v_missing || 'canvas_positions'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.canvas_templates WHERE name = 'dr template') THEN v_missing := v_missing || 'canvas_templates'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.capability_versions WHERE change_note = 'dump/restore fixture') THEN v_missing := v_missing || 'capability_versions'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.capability_evaluations WHERE content_hash = 'dr-fixture') THEN v_missing := v_missing || 'capability_evaluations'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.capability_search_events WHERE query_text = 'dump/restore fixture') THEN v_missing := v_missing || 'capability_search_events'::text; END IF;
  IF EXISTS (SELECT 1 FROM allgres_private.web_sessions) THEN v_missing := v_missing || 'web_sessions must be empty after restore'::text; END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'dump/restore verify: fixture rows missing after restore: %', v_missing;
  END IF;
  -- The provider key is ciphertext in the dump; it must decrypt with the
  -- restored cluster's allgres.secret_key.
  IF allgres_private.decrypt_secret((SELECT s.api_key FROM allgres_private.llm_secrets s
        JOIN allgres_private.llm_providers p USING (provider_id) WHERE p.name = 'dr_mock'))
     IS DISTINCT FROM 'dr-fixture-api-key' THEN
    RAISE EXCEPTION 'dump/restore verify: dr_mock api key does not decrypt after restore';
  END IF;
  RAISE NOTICE 'dump/restore verify: fixture rows present, web_sessions empty, secret decrypts';
END
$block$;
SELECT 'dump/restore verify ok' AS result;
