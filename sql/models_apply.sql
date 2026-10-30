-- One model for many agents at once, and a default for new agents
-- (docs/models-apply.md). Deliberately explicit: an administrator picks the
-- targets, sees what will change, and the change is written into each agent's
-- own policy and into the audit log. There is no hidden fallback model that an
-- agent with nothing set reaches at run time; the default below is only
-- copied onto an agent when it is created.

CREATE TABLE IF NOT EXISTS allgres_private.model_defaults (
  singleton  boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  provider   text NOT NULL,
  model      text NOT NULL CHECK (btrim(model) <> ''),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES allgres_private.users(user_id) ON DELETE SET NULL
);

-- A new agent gets the default's provider and model when it was created with
-- none. An agent that already exists is never touched by this.
CREATE OR REPLACE FUNCTION allgres_private.apply_model_default_to_new_agent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  d allgres_private.model_defaults%ROWTYPE;
  a allgres_private.agents%ROWTYPE;
BEGIN
  SELECT * INTO a FROM allgres_private.agents WHERE agent_id = NEW.agent_id;
  IF a.is_system THEN RETURN NEW; END IF;
  SELECT * INTO d FROM allgres_private.model_defaults;
  IF FOUND AND COALESCE(NEW.llm_config->>'model', '') = '' THEN
    NEW.llm_config := COALESCE(NEW.llm_config, '{}'::jsonb)
      || jsonb_build_object('provider', d.provider, 'model', d.model);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS apply_model_default_to_new_agent ON allgres_private.policies;
CREATE TRIGGER apply_model_default_to_new_agent
  BEFORE INSERT ON allgres_private.policies
  FOR EACH ROW EXECUTE FUNCTION allgres_private.apply_model_default_to_new_agent();

CREATE OR REPLACE FUNCTION allgres_private.models_check_target(p_provider text, p_model text)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF btrim(COALESCE(p_model, '')) = '' THEN
    RAISE EXCEPTION 'give the model name' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.llm_providers
                 WHERE name = p_provider AND is_enabled AND purpose = 'chat') THEN
    RAISE EXCEPTION 'pick an enabled chat provider' USING ERRCODE = 'P0001';
  END IF;
END;
$fn$;

-- What can be changed, and what it is set to now.
CREATE OR REPLACE FUNCTION allgres_public.fn_models_targets()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'default', (SELECT jsonb_build_object('provider', provider, 'model', model, 'updated_at', updated_at) FROM allgres_private.model_defaults),
    'agents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'agent_id', a.agent_id, 'name', a.name, 'is_active', a.is_active,
        'provider', p.llm_config->>'provider', 'model', p.llm_config->>'model') ORDER BY a.name)
      FROM allgres_private.agents a JOIN allgres_private.policies p ON p.agent_id = a.agent_id
      WHERE NOT a.is_system AND a.name <> 'health_monitor'), '[]'::jsonb),
    'functions', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'function_id', f.function_id, 'name', f.name, 'override', f.llm_override) ORDER BY f.name)
      FROM allgres_private.functions f), '[]'::jsonb),
    'procedures', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'procedure_id', pr.procedure_id, 'name', pr.name, 'override', pr.llm_override) ORDER BY pr.name)
      FROM allgres_private.procedures pr), '[]'::jsonb))
$fn$;

-- Sets the model on the chosen agents (or every ordinary agent), and on the
-- chosen functions and procedures as their own override. Only provider and
-- model change; everything else in a policy stays. System agents are never
-- touched. What each one had before is kept in the audit entry.
CREATE OR REPLACE FUNCTION allgres_public.fn_models_apply(
  p_token text, p_provider text, p_model text,
  p_all_agents boolean DEFAULT false, p_agent_ids uuid[] DEFAULT NULL,
  p_function_ids uuid[] DEFAULT NULL, p_procedure_ids uuid[] DEFAULT NULL,
  p_set_default boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE := allgres_private.require_admin(p_token);
  v_cfg jsonb;
  v_agent record;
  v_before jsonb := '[]'::jsonb;
  v_changed int := 0;
  v_failed jsonb := '[]'::jsonb;
  v_funcs int := 0;
  v_procs int := 0;
BEGIN
  PERFORM allgres_private.models_check_target(p_provider, p_model);
  PERFORM allgres_private.models_check_enabled(p_provider, p_model);
  PERFORM allgres_private.models_register(p_provider, p_model);
  v_cfg := jsonb_build_object('provider', p_provider, 'model', btrim(p_model));
  FOR v_agent IN
    SELECT a.agent_id, a.name, p.llm_config
    FROM allgres_private.agents a JOIN allgres_private.policies p ON p.agent_id = a.agent_id
    WHERE NOT a.is_system AND a.name <> 'health_monitor'
      AND (COALESCE(p_all_agents, false) OR a.agent_id = ANY (COALESCE(p_agent_ids, ARRAY[]::uuid[])))
    ORDER BY a.name
  LOOP
    BEGIN
      PERFORM allgres_public.fn_set_policy(v_agent.agent_id, NULL, NULL, NULL, v_cfg);
      v_before := v_before || jsonb_build_array(jsonb_build_object(
        'agent', v_agent.name, 'provider', v_agent.llm_config->>'provider', 'model', v_agent.llm_config->>'model'));
      v_changed := v_changed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed || jsonb_build_array(jsonb_build_object('agent', v_agent.name, 'error', left(SQLERRM, 200)));
    END;
  END LOOP;
  IF p_function_ids IS NOT NULL THEN
    UPDATE allgres_private.functions SET llm_override = v_cfg WHERE function_id = ANY (p_function_ids);
    GET DIAGNOSTICS v_funcs = ROW_COUNT;
  END IF;
  IF p_procedure_ids IS NOT NULL THEN
    UPDATE allgres_private.procedures SET llm_override = v_cfg WHERE procedure_id = ANY (p_procedure_ids);
    GET DIAGNOSTICS v_procs = ROW_COUNT;
  END IF;
  IF COALESCE(p_set_default, false) THEN
    INSERT INTO allgres_private.model_defaults (provider, model, updated_by) VALUES (p_provider, btrim(p_model), u.user_id)
    ON CONFLICT (singleton) DO UPDATE SET provider = EXCLUDED.provider, model = EXCLUDED.model, updated_at = now(), updated_by = u.user_id;
  END IF;
  PERFORM allgres_private.audit('models.apply', jsonb_build_object(
    'provider', p_provider, 'model', btrim(p_model), 'agents', v_changed, 'functions', v_funcs, 'procedures', v_procs,
    'set_default', COALESCE(p_set_default, false), 'before', v_before, 'failed', v_failed));
  RETURN jsonb_build_object('ok', true, 'agents', v_changed, 'functions', v_funcs, 'procedures', v_procs,
                            'failed', v_failed, 'default_set', COALESCE(p_set_default, false));
END;
$fn$;

-- Functions and procedures go back to using the calling agent's own model.
CREATE OR REPLACE FUNCTION allgres_public.fn_models_clear_overrides(
  p_token text, p_function_ids uuid[] DEFAULT NULL, p_procedure_ids uuid[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_f int := 0; v_p int := 0;
BEGIN
  PERFORM allgres_private.require_admin(p_token);
  IF p_function_ids IS NOT NULL THEN
    UPDATE allgres_private.functions SET llm_override = NULL WHERE function_id = ANY (p_function_ids) AND llm_override IS NOT NULL;
    GET DIAGNOSTICS v_f = ROW_COUNT;
  END IF;
  IF p_procedure_ids IS NOT NULL THEN
    UPDATE allgres_private.procedures SET llm_override = NULL WHERE procedure_id = ANY (p_procedure_ids) AND llm_override IS NOT NULL;
    GET DIAGNOSTICS v_p = ROW_COUNT;
  END IF;
  PERFORM allgres_private.audit('models.clear_overrides', jsonb_build_object('functions', v_f, 'procedures', v_p));
  RETURN jsonb_build_object('ok', true, 'functions', v_f, 'procedures', v_p);
END;
$fn$;

-- Forget the default for new agents.
CREATE OR REPLACE FUNCTION allgres_public.fn_model_default_clear(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  PERFORM allgres_private.require_admin(p_token);
  DELETE FROM allgres_private.model_defaults;
  PERFORM allgres_private.audit('models.default_clear', '{}'::jsonb);
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- The model registry: which models each provider offers to this installation.
-- A model is a row under its provider (on or off, with a note and its default
-- inference settings); its price stays in llm_model_prices. An agent's model is
-- still its own provider and model in its policy; the registry is what an
-- administrator picks from, and what a model row's "use on agents" acts on.
-- A model an agent already uses is added by itself (source 'used'), so nothing
-- that worked before is lost.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS allgres_private.llm_models (
  provider_id uuid NOT NULL REFERENCES allgres_private.llm_providers(provider_id) ON DELETE CASCADE,
  model       text NOT NULL CHECK (btrim(model) <> ''),
  is_enabled  boolean NOT NULL DEFAULT true,
  source      text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'listed', 'used')),
  note        text,
  params      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(params) = 'object'),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider_id, model)
);

CREATE OR REPLACE FUNCTION allgres_private.models_register(p_provider text, p_model text, p_source text DEFAULT 'used')
RETURNS void
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF btrim(COALESCE(p_model, '')) = '' OR btrim(COALESCE(p_provider, '')) = '' THEN
    RETURN;
  END IF;
  INSERT INTO allgres_private.llm_models (provider_id, model, source)
  SELECT provider_id, btrim(p_model), p_source FROM allgres_private.llm_providers WHERE name = p_provider
  ON CONFLICT (provider_id, model) DO NOTHING;
END;
$fn$;

-- Whatever model a policy names is a registry row.
CREATE OR REPLACE FUNCTION allgres_private.register_used_model()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  PERFORM allgres_private.models_register(NEW.llm_config->>'provider', NEW.llm_config->>'model');
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS register_used_model ON allgres_private.policies;
CREATE TRIGGER register_used_model
  AFTER INSERT OR UPDATE OF llm_config ON allgres_private.policies
  FOR EACH ROW EXECUTE FUNCTION allgres_private.register_used_model();

-- What already exists: agents, function and procedure overrides, prices, the default.
INSERT INTO allgres_private.llm_models (provider_id, model, source)
SELECT DISTINCT pr.provider_id, btrim(x.model), 'used'
FROM (
  SELECT llm_config->>'provider' AS provider, llm_config->>'model' AS model FROM allgres_private.policies
  UNION SELECT llm_override->>'provider', llm_override->>'model' FROM allgres_private.functions WHERE llm_override IS NOT NULL
  UNION SELECT llm_override->>'provider', llm_override->>'model' FROM allgres_private.procedures WHERE llm_override IS NOT NULL
  UNION SELECT provider, model FROM allgres_private.model_defaults
) x
JOIN allgres_private.llm_providers pr ON pr.name = x.provider
WHERE btrim(COALESCE(x.model, '')) <> ''
ON CONFLICT (provider_id, model) DO NOTHING;
INSERT INTO allgres_private.llm_models (provider_id, model, source)
SELECT provider_id, model, 'used' FROM allgres_private.llm_model_prices
ON CONFLICT (provider_id, model) DO NOTHING;

-- A model that is switched off cannot be put on agents.
CREATE OR REPLACE FUNCTION allgres_private.models_check_enabled(p_provider text, p_model text)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM allgres_private.llm_models m JOIN allgres_private.llm_providers p USING (provider_id)
             WHERE p.name = p_provider AND m.model = btrim(p_model) AND NOT m.is_enabled) THEN
    RAISE EXCEPTION 'the model % is switched off; turn it on first', btrim(p_model) USING ERRCODE = 'P0001';
  END IF;
END;
$fn$;

-- Providers with their models, what each costs, who uses it, and what the
-- provider itself lists that is not added yet.
CREATE OR REPLACE FUNCTION allgres_public.fn_models_registry(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_out jsonb;
BEGIN
  PERFORM allgres_private.require_admin(p_token);
  SELECT jsonb_build_object(
    'default', (SELECT jsonb_build_object('provider', provider, 'model', model) FROM allgres_private.model_defaults),
    'providers', COALESCE(jsonb_agg(jsonb_build_object(
      'provider_id', p.provider_id, 'name', p.name, 'kind', p.kind, 'is_enabled', p.is_enabled,
      'last_probe_status', p.last_probe_status, 'last_chat_status', p.last_chat_status,
      'models', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'model', m.model, 'is_enabled', m.is_enabled, 'source', m.source, 'note', m.note, 'params', m.params,
          'input_price_per_1k', pr.input_price_per_1k, 'output_price_per_1k', pr.output_price_per_1k,
          'agents', COALESCE((SELECT jsonb_agg(a.name ORDER BY a.name)
                              FROM allgres_private.policies po JOIN allgres_private.agents a ON a.agent_id = po.agent_id
                              WHERE NOT a.is_system AND po.llm_config->>'provider' = p.name AND po.llm_config->>'model' = m.model), '[]'::jsonb),
          'functions', (SELECT count(*) FROM allgres_private.functions f WHERE f.llm_override->>'provider' = p.name AND f.llm_override->>'model' = m.model)
                     + (SELECT count(*) FROM allgres_private.procedures q WHERE q.llm_override->>'provider' = p.name AND q.llm_override->>'model' = m.model),
          'is_default', EXISTS (SELECT 1 FROM allgres_private.model_defaults d WHERE d.provider = p.name AND d.model = m.model)
        ) ORDER BY m.model)
        FROM allgres_private.llm_models m
        LEFT JOIN allgres_private.llm_model_prices pr ON pr.provider_id = m.provider_id AND pr.model = m.model
        WHERE m.provider_id = p.provider_id), '[]'::jsonb),
      'available', COALESCE((
        SELECT jsonb_agg(x ORDER BY x) FROM (
          SELECT e AS x FROM jsonb_array_elements_text(COALESCE(p.available_models, '[]'::jsonb)) e
          WHERE NOT EXISTS (SELECT 1 FROM allgres_private.llm_models m WHERE m.provider_id = p.provider_id AND m.model = e)
          LIMIT 500) t), '[]'::jsonb)
    ) ORDER BY p.name), '[]'::jsonb))
  INTO v_out
  FROM allgres_private.llm_providers p
  WHERE p.purpose = 'chat';
  RETURN v_out;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_models_registry_add(
  p_token text, p_provider text, p_models text[], p_enabled boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_n int;
BEGIN
  PERFORM allgres_private.require_admin(p_token);
  SELECT provider_id INTO v_id FROM allgres_private.llm_providers WHERE name = p_provider AND purpose = 'chat';
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'pick a chat provider' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.llm_models (provider_id, model, is_enabled, source)
  SELECT v_id, btrim(m), COALESCE(p_enabled, true), 'manual'
  FROM unnest(COALESCE(p_models, ARRAY[]::text[])) m WHERE btrim(m) <> ''
  ON CONFLICT (provider_id, model) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM allgres_private.audit('models.registry_add', jsonb_build_object('provider', p_provider, 'added', v_n));
  RETURN jsonb_build_object('ok', true, 'added', v_n);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_models_registry_set(
  p_token text, p_provider text, p_model text,
  p_enabled boolean DEFAULT NULL, p_note text DEFAULT NULL, p_params jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  PERFORM allgres_private.require_admin(p_token);
  SELECT provider_id INTO v_id FROM allgres_private.llm_providers WHERE name = p_provider;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.llm_models WHERE provider_id = v_id AND model = p_model) THEN
    RAISE EXCEPTION 'that model is not in the list' USING ERRCODE = 'P0001';
  END IF;
  IF p_params IS NOT NULL AND jsonb_typeof(p_params) <> 'object' THEN
    RAISE EXCEPTION 'settings must be an object' USING ERRCODE = 'P0001';
  END IF;
  IF p_params IS NOT NULL THEN
    PERFORM allgres_private.llm_params_check(p_params);
    p_params := allgres_private.sanitize_llm_config(p_params) - 'model' - 'provider';
  END IF;
  UPDATE allgres_private.llm_models
  SET is_enabled = COALESCE(p_enabled, is_enabled),
      note = CASE WHEN p_note IS NULL THEN note ELSE NULLIF(btrim(p_note), '') END,
      params = COALESCE(p_params, params)
  WHERE provider_id = v_id AND model = p_model;
  PERFORM allgres_private.audit('models.registry_set', jsonb_build_object(
    'provider', p_provider, 'model', p_model, 'enabled', p_enabled));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_models_registry_remove(p_token text, p_provider text, p_model text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_used int;
BEGIN
  PERFORM allgres_private.require_admin(p_token);
  SELECT provider_id INTO v_id FROM allgres_private.llm_providers WHERE name = p_provider;
  SELECT (SELECT count(*) FROM allgres_private.policies po JOIN allgres_private.agents a ON a.agent_id = po.agent_id
          WHERE po.llm_config->>'provider' = p_provider AND po.llm_config->>'model' = p_model)
       + (SELECT count(*) FROM allgres_private.functions WHERE llm_override->>'provider' = p_provider AND llm_override->>'model' = p_model)
       + (SELECT count(*) FROM allgres_private.procedures WHERE llm_override->>'provider' = p_provider AND llm_override->>'model' = p_model)
       + (SELECT count(*) FROM allgres_private.model_defaults WHERE provider = p_provider AND model = p_model)
  INTO v_used;
  IF v_used > 0 THEN
    RAISE EXCEPTION 'that model is still in use (% place(s)); switch it off, or move them to another model first', v_used USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM allgres_private.llm_models WHERE provider_id = v_id AND model = p_model;
  PERFORM allgres_private.audit('models.registry_remove', jsonb_build_object('provider', p_provider, 'model', p_model));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Models an agent may use. An agent with none ticked may use any model that is
-- switched on; with some ticked, only those (its own model, a person's choice
-- in General, a model picked for one task). A function or procedure's own
-- override and a model experiment are the administrator's own choice and are
-- not held to the list. A model that is switched off is refused for everyone.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS allgres_private.agent_models (
  agent_id    uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  provider_id uuid NOT NULL REFERENCES allgres_private.llm_providers(provider_id) ON DELETE CASCADE,
  model       text NOT NULL,
  PRIMARY KEY (agent_id, provider_id, model)
);

-- Why this model cannot be used by this agent, or NULL when it can.
CREATE OR REPLACE FUNCTION allgres_private.agent_model_issue(
  p_agent_id uuid, p_provider text, p_model text, p_override boolean DEFAULT false
) RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_pid uuid;
  v_enabled boolean;
BEGIN
  IF btrim(COALESCE(p_provider, '')) = '' OR btrim(COALESCE(p_model, '')) = '' THEN
    RETURN 'no model is chosen: set a provider and a model for this agent';
  END IF;
  SELECT provider_id, is_enabled INTO v_pid, v_enabled FROM allgres_private.llm_providers WHERE name = p_provider;
  IF v_pid IS NULL THEN
    RETURN format('the provider "%s" does not exist', p_provider);
  END IF;
  IF NOT v_enabled THEN
    RETURN format('the provider "%s" is switched off', p_provider);
  END IF;
  IF EXISTS (SELECT 1 FROM allgres_private.llm_models WHERE provider_id = v_pid AND model = p_model AND NOT is_enabled) THEN
    RETURN format('the model "%s" is switched off in Models & prices', p_model);
  END IF;
  IF NOT COALESCE(p_override, false)
     AND EXISTS (SELECT 1 FROM allgres_private.agent_models WHERE agent_id = p_agent_id)
     AND NOT EXISTS (SELECT 1 FROM allgres_private.agent_models WHERE agent_id = p_agent_id AND provider_id = v_pid AND model = p_model) THEN
    RETURN format('the model "%s" is not among the models this agent may use', p_model);
  END IF;
  RETURN NULL;
END;
$fn$;

-- Set the models an agent may use. An empty list means any model that is on.
CREATE OR REPLACE FUNCTION allgres_public.fn_agent_set_allowed_models(p_token text, p_agent_id uuid, p_models jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  m jsonb;
  v_pid uuid;
  v_n int := 0;
BEGIN
  PERFORM allgres_private.require_admin(p_token);
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id) THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.forbid_system_agent_edit(p_agent_id);
  IF p_models IS NULL OR jsonb_typeof(p_models) <> 'array' THEN
    RAISE EXCEPTION 'give the models as a list' USING ERRCODE = 'P0001';
  END IF;
  FOR m IN SELECT * FROM jsonb_array_elements(p_models) LOOP
    SELECT provider_id INTO v_pid FROM allgres_private.llm_providers WHERE name = m->>'provider' AND purpose = 'chat';
    IF v_pid IS NULL OR NOT EXISTS (SELECT 1 FROM allgres_private.llm_models WHERE provider_id = v_pid AND model = m->>'model') THEN
      RAISE EXCEPTION 'the model % / % is not in the list of models', m->>'provider', m->>'model' USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  DELETE FROM allgres_private.agent_models WHERE agent_id = p_agent_id;
  INSERT INTO allgres_private.agent_models (agent_id, provider_id, model)
  SELECT p_agent_id, pr.provider_id, e->>'model'
  FROM jsonb_array_elements(p_models) e
  JOIN allgres_private.llm_providers pr ON pr.name = e->>'provider'
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM allgres_private.audit('agents.set_allowed_models', jsonb_build_object('agent_id', p_agent_id, 'models', v_n));
  RETURN jsonb_build_object('ok', true, 'models', v_n);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.agent_allowed_models(p_agent_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('provider', p.name, 'model', am.model) ORDER BY p.name, am.model), '[]'::jsonb)
  FROM allgres_private.agent_models am JOIN allgres_private.llm_providers p USING (provider_id)
  WHERE am.agent_id = p_agent_id
$fn$;

-- A model's own default inference settings (what the agent does not set itself).
CREATE OR REPLACE FUNCTION allgres_private.llm_model_params(p_provider text, p_model text)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT COALESCE((SELECT m.params FROM allgres_private.llm_models m
                   JOIN allgres_private.llm_providers p USING (provider_id)
                   WHERE p.name = p_provider AND m.model = p_model), '{}'::jsonb)
$fn$;
