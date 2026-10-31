-- Per-user interface settings (docs/user-prefs.md): language, theme and the
-- small view states (open panels, chosen tabs). They live in the database,
-- one row per user, so they follow the person to any browser. Nothing here is
-- a secret and nothing here changes what a user may do.
CREATE TABLE IF NOT EXISTS allgres_private.user_ui_prefs (
  user_id    uuid PRIMARY KEY REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  prefs      jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(prefs) = 'object')
);

-- Keys are lowercase words with _ . - ; values are short strings, so the row
-- cannot grow into a general data store. A null value removes the key.
CREATE OR REPLACE FUNCTION allgres_private.ui_prefs_check(p jsonb)
RETURNS void LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE r record;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'prefs must be an object' USING ERRCODE='22023';
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(p)) > 64 THEN
    RAISE EXCEPTION 'too many settings at once' USING ERRCODE='22023';
  END IF;
  FOR r IN SELECT key, value FROM jsonb_each(p) LOOP
    IF r.key !~ '^[a-z][a-z0-9_.-]{0,47}$' THEN
      RAISE EXCEPTION 'bad setting name: %', left(r.key, 50) USING ERRCODE='22023';
    END IF;
    IF jsonb_typeof(r.value) NOT IN ('string', 'null') OR length(r.value #>> '{}') > 200 THEN
      RAISE EXCEPTION 'setting % must be a short text', r.key USING ERRCODE='22023';
    END IF;
  END LOOP;
  IF p ? 'lang' AND jsonb_typeof(p->'lang') = 'string' AND (p->>'lang') !~ '^[a-z]{2,3}(-[A-Za-z0-9]+)?$' THEN
    RAISE EXCEPTION 'bad language code' USING ERRCODE='22023';
  END IF;
  IF p ? 'theme' AND jsonb_typeof(p->'theme') = 'string' AND (p->>'theme') NOT IN ('light', 'dark') THEN
    RAISE EXCEPTION 'theme must be light or dark' USING ERRCODE='22023';
  END IF;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_ui_prefs_get(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE u allgres_private.users%ROWTYPE;
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL THEN RAISE EXCEPTION 'not logged in' USING ERRCODE='P0001'; END IF;
  RETURN jsonb_build_object('ok', true, 'prefs',
    COALESCE((SELECT prefs FROM allgres_private.user_ui_prefs WHERE user_id = u.user_id), '{}'::jsonb));
END;
$fn$;

-- Merges the given settings into the user's row; a null value clears a key.
CREATE OR REPLACE FUNCTION allgres_public.fn_ui_prefs_set(p_token text, p_prefs jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE u allgres_private.users%ROWTYPE; v jsonb;
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL THEN RAISE EXCEPTION 'not logged in' USING ERRCODE='P0001'; END IF;
  PERFORM allgres_private.ui_prefs_check(p_prefs);
  INSERT INTO allgres_private.user_ui_prefs(user_id, prefs)
  VALUES (u.user_id, jsonb_strip_nulls(p_prefs))
  ON CONFLICT (user_id) DO UPDATE
    SET prefs = jsonb_strip_nulls(user_ui_prefs.prefs || p_prefs), updated_at = now()
  RETURNING prefs INTO v;
  IF (SELECT count(*) FROM jsonb_object_keys(v)) > 64 THEN
    RAISE EXCEPTION 'too many settings saved' USING ERRCODE='22023';
  END IF;
  RETURN jsonb_build_object('ok', true, 'prefs', v);
END;
$fn$;
