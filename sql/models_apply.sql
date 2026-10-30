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
