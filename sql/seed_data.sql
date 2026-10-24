-- Allgres 0.1.0-alpha.1 control plane -- section 10: seed data (create-only --
-- replaying this file must not clobber an operator's edited prompt,
-- provider list, or policy) and section 10b: extension configuration
-- tables (pg_dump data inclusion).
--
-- Split out of sql/control_plane.sql once that single file grew large
-- enough to trip a real rustc compile-time safety lint (KNOWN_ISSUES.md
-- item 38). Everything here is a top-level INSERT/UPDATE or an anonymous
-- DO block that reaches into tables directly (never through an operator-
-- API function), so the only real dependency is on sections 1-8 (sql/
-- control_plane.sql) having already created those tables -- loaded after
-- the three operator-API files anyway (`requires = ["operator_accounts_
-- and_chat"]`) purely to preserve this content's original position in one
-- file, not because it calls into any of them. Loaded before
-- sql/selftest.sql.
-- ---------------------------------------------------------------------------
-- 10. Seed data.  Create-only: replaying this file must not clobber an
--     operator's edited prompt, provider list, or policy.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 10-0. Seed marker. Every row this section creates is flagged is_seed =
-- true, and section 10b dumps only `WHERE NOT is_seed` from these tables:
-- CREATE EXTENSION re-creates the seed on restore, so dumping a seed row too
-- would COPY a second copy on top of it and fail on its unique key (it did,
-- for functions, procedures, llm_providers and sql_sandbox_allowlist, while
-- the old per-table name lists drifted from what was actually seeded).
--
-- An edited seed row stays seed: like an edited built-in provider before
-- this, its edits are not part of a logical (pg_dump) backup and a restore
-- brings back the shipped version; a deleted seed row comes back too.
-- Nothing clears the flag. Physical backups keep everything.
--
-- Seed rows also use fixed ids (agents, the seoul-weather procedure and
-- seoul_weather function, like llm_providers' provider_id below), so user
-- rows that point at them (sessions on 'general', a user grant to
-- 'analyst', a user procedure bound to seoul_weather) still match after a
-- restore onto a fresh install.
--
-- mark_seed_rows() is the one definition of which rows are seed, by natural
-- key, so an upgrade script can add the columns and mark an existing
-- install's seed rows with the same call. Idempotent; returns how many rows
-- it marked per table (p_dry_run: how many it would mark, changing nothing).
-- ---------------------------------------------------------------------------
ALTER TABLE allgres_private.agents ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.policies ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.permissions ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.demo_sales ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.llm_providers ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.sql_sandbox_allowlist ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.functions ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.procedures ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
ALTER TABLE allgres_private.procedure_function_bindings ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION allgres_private.mark_seed_rows(p_dry_run boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_counts jsonb := '{}'::jsonb;
  v_sql text;
  v_n bigint;
  t record;
  -- The built-in agents, by name; the five system ones must also be is_system.
  v_seed_agents constant text := $q$(SELECT sa.agent_id FROM allgres_private.agents sa
    WHERE sa.name IN ('analyst', 'general', 'health_monitor')
       OR (sa.is_system AND sa.name IN ('system_root', 'session_compactor', 'creator', 'fixer', 'self_improve')))$q$;
BEGIN
  FOR t IN SELECT * FROM (VALUES
    ('agents', $w$agent_id IN %1$s$w$),
    ('policies', $w$agent_id IN %1$s$w$),
    ('permissions', $w$(agent_id, resource_type, resource_ref) IN (
        SELECT a.agent_id, x.resource_type, x.resource_ref
        FROM allgres_private.agents a
        JOIN (VALUES
          ('analyst', 'view', 'allgres_public.v_sales'),
          ('analyst', 'view', 'allgres_public.v_my_tasks'),
          ('analyst', 'function', 'http_get'),
          ('general', 'procedure', 'seoul-weather'),
          ('health_monitor', 'view', 'allgres_public.v_system_health'),
          ('health_monitor', 'view', 'allgres_public.v_permission_audit'),
          ('health_monitor', 'view', 'allgres_public.v_agent_health'),
          ('fixer', 'view', 'allgres_public.v_system_health'),
          ('fixer', 'view', 'allgres_public.v_permission_audit'),
          ('self_improve', 'view', 'allgres_public.v_agent_health'),
          ('self_improve', 'view', 'allgres_public.v_function_model_experiments')
        ) AS x(agent_name, resource_type, resource_ref) ON x.agent_name = a.name
        WHERE a.agent_id IN %1$s)$w$),
    ('demo_sales', $w$agent_id IN (SELECT a.agent_id FROM allgres_private.agents a
                                   WHERE a.name = 'analyst' AND a.agent_id IN %1$s)
        AND (region, sku, amount, sold_on) IN (VALUES
          ('seoul',   'ARB-1', 1200.00::numeric, DATE '2026-08-01'),
          ('seoul',   'ARB-2',  840.50::numeric, DATE '2026-08-03'),
          ('busan',   'ARB-1',  410.00::numeric, DATE '2026-08-04'),
          ('incheon', 'ARB-3', 1920.00::numeric, DATE '2026-08-07'),
          ('busan',   'ARB-2',  275.25::numeric, DATE '2026-08-12'))$w$),
    ('llm_providers', $w$name IN ('xai', 'openai', 'anthropic', 'ollama', 'openai_compat', 'xai_oauth')$w$),
    ('sql_sandbox_allowlist', $w$resource_ref IN ('allgres_public.v_sales', 'allgres_public.v_my_tasks',
        'allgres_public.v_system_health', 'allgres_public.v_permission_audit',
        'allgres_public.v_agent_health', 'allgres_public.v_function_model_experiments')$w$),
    ('functions', $w$name = 'seoul_weather'$w$),
    ('procedures', $w$name = 'seoul-weather'$w$),
    ('procedure_function_bindings', $w$(procedure_id, function_id) IN (
        SELECT p.procedure_id, f.function_id
        FROM allgres_private.procedures p, allgres_private.functions f
        WHERE p.name = 'seoul-weather' AND f.name = 'seoul_weather')$w$)
  ) AS v(tbl, cond)
  LOOP
    t.cond := replace(t.cond, '%1$s', v_seed_agents);
    IF p_dry_run THEN
      v_sql := format('SELECT count(*) FROM allgres_private.%I WHERE NOT is_seed AND (%s)', t.tbl, t.cond);
      EXECUTE v_sql INTO v_n;
    ELSE
      v_sql := format('UPDATE allgres_private.%I SET is_seed = true WHERE NOT is_seed AND (%s)', t.tbl, t.cond);
      EXECUTE v_sql;
      GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    v_counts := v_counts || jsonb_build_object(t.tbl, v_n);
  END LOOP;
  RETURN v_counts;
END;
$fn$;

-- Fixed provider_id values, not the column's gen_random_uuid() default: a
-- random id here would differ between any two installs of this same seed
-- (a fresh install vs. a restore target, most concretely), breaking every
-- FK that points at a built-in provider (llm_secrets, outbound_calls) the
-- moment that data crosses installs -- see KNOWN_ISSUES.md, "backup/PITR
-- drill". ON CONFLICT (name) DO NOTHING means this is forward-only: an
-- install that already seeded these rows before this fix keeps whatever
-- random id it already has, since the row already exists by name; only a
-- fresh install (or a restore onto one) gets the fixed id from here on.
INSERT INTO allgres_private.llm_providers (provider_id, name, kind, base_url, is_enabled, allow_private_network)
VALUES
  ('157b9a61-537b-4faf-a88a-c673ab3fad8e', 'xai',           'openai_compat', 'https://api.x.ai/v1',        true,  false),
  ('f87649ff-8541-4404-a505-5508d59812e2', 'openai',        'openai_compat', 'https://api.openai.com/v1',  true,  false),
  ('b73bdab2-66a7-4eb8-9906-6f0ee2b9f32c', 'anthropic',     'anthropic',     'https://api.anthropic.com',  true,  false),
  ('21b55be9-aef4-4709-8a65-b3dc10e008ac', 'ollama',        'openai_compat', 'http://127.0.0.1:11434/v1',  true,  true),
  ('93ad5476-8d3a-4443-8b98-f50b6d1d4fbc', 'openai_compat', 'openai_compat', 'https://api.openai.com/v1',  true,  false)
ON CONFLICT (name) DO NOTHING;

-- Public-client device OAuth used by xAI's Grok CLI/Hermes-compatible login.
-- The client id is not a secret; the issued device/access/refresh credentials
-- are encrypted in llm_secrets/oauth_device_sessions and never listed.
INSERT INTO allgres_private.llm_providers (
  provider_id,name,kind,base_url,is_enabled,allow_private_network,
  oauth_flow,oauth_device_url,oauth_token_url,oauth_client_id,oauth_scope
) VALUES (
  '98f88f1a-607d-4b54-b820-66dc40b70449','xai_oauth','oauth','https://api.x.ai/v1',true,false,
  'device_code','https://auth.x.ai/oauth2/device/code','https://auth.x.ai/oauth2/token',
  'b1a00492-073a-47ea-816f-4c329264a828',
  'openid profile email offline_access grok-cli:access api:access'
)
ON CONFLICT (name) DO UPDATE SET
  kind=EXCLUDED.kind, base_url=EXCLUDED.base_url, oauth_flow=EXCLUDED.oauth_flow,
  oauth_device_url=EXCLUDED.oauth_device_url, oauth_token_url=EXCLUDED.oauth_token_url,
  oauth_client_id=EXCLUDED.oauth_client_id, oauth_scope=EXCLUDED.oauth_scope;

-- response_format_json_object's own retroactive fix (its column comment
-- above explains why): must run after the INSERT above, whether that
-- INSERT just created the row (fresh install) or found it already there
-- and did nothing (ON CONFLICT DO NOTHING, an existing install) -- either
-- way the row exists by the time this runs, unlike the ALTER TABLE far
-- above it. Unconditional on every re-run of this file, not gated by
-- whether the row was just inserted, so an install that already had the
-- pre-fix default overwritten some other way is also corrected the next
-- time control_plane.sql is applied.
UPDATE allgres_private.llm_providers SET response_format_json_object = false WHERE name = 'ollama';

INSERT INTO allgres_private.sql_sandbox_allowlist (resource_ref)
VALUES ('allgres_public.v_sales'), ('allgres_public.v_my_tasks'),
       ('allgres_public.v_system_health'), ('allgres_public.v_permission_audit'),
       ('allgres_public.v_agent_health'), ('allgres_public.v_function_model_experiments')
ON CONFLICT DO NOTHING;

DO $seed$
DECLARE
  v_agent uuid;
BEGIN
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'analyst';

  IF v_agent IS NULL THEN
    INSERT INTO allgres_private.agents (agent_id, name)
    VALUES ('54d7c90c-c0c8-42f4-9d05-9ddaaf19ecd9', 'analyst') RETURNING agent_id INTO v_agent;

    -- Only on first creation, so an upgrade never overwrites a tuned policy.
    UPDATE allgres_private.policies
    SET system_prompt = $prompt$You are the Allgres analyst. Reply with one JSON object only. No markdown, no prose.

Allowed:
{"action":"final_answer","answer":"..."}
{"action":"execute_sql","sql":"SELECT ..."}
{"action":"call_function","function":"http_get","args":{"url":"https://..."}}
{"action":"await_human","reason":"..."}

For numbers use execute_sql against allgres_public.v_sales (region, sku, amount, sold_on).
Example: {"action":"execute_sql","sql":"SELECT region, sum(amount) AS total FROM allgres_public.v_sales GROUP BY region"}
When you have the result, emit final_answer in one short sentence.
$prompt$,
        max_steps = 8,
        max_retries = 2,
        -- Deliberately no llm_config here (see ensure_policy): a fresh
        -- install must not look like a provider was already picked and
        -- authenticated when nothing has actually been configured yet.
        updated_at = now()
    WHERE agent_id = v_agent;
  END IF;

  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  SELECT v_agent, x.resource_type, x.resource_ref
  FROM (VALUES
    ('view', 'allgres_public.v_sales'),
    ('view', 'allgres_public.v_my_tasks'),
    ('function', 'http_get')
  ) AS x(resource_type, resource_ref)
  ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;

  IF NOT EXISTS (SELECT 1 FROM allgres_private.demo_sales WHERE agent_id = v_agent) THEN
    INSERT INTO allgres_private.demo_sales (agent_id, region, sku, amount, sold_on)
    SELECT v_agent, s.region, s.sku, s.amount, s.sold_on
    FROM (VALUES
      ('seoul',   'ARB-1', 1200.00, DATE '2026-08-01'),
      ('seoul',   'ARB-2',  840.50, DATE '2026-08-03'),
      ('busan',   'ARB-1',  410.00, DATE '2026-08-04'),
      ('incheon', 'ARB-3', 1920.00, DATE '2026-08-07'),
      ('busan',   'ARB-2',  275.25, DATE '2026-08-12')
    ) AS s(region, sku, amount, sold_on);
  END IF;
END
$seed$;

-- A second, deliberately plain demo agent for the Chat page's own "General"
-- tab: item 39's own follow-up to that tab always needing an agent picked
-- from a dropdown first, reported live as friction an operator (or a
-- regular user with exactly one thing they want to talk to) shouldn't have
-- to deal with just to say hello. Unlike 'analyst' it holds no view/function
-- permissions and no demo data -- a plain conversational partner, not a
-- data-query one -- so its own prompt never offers execute_sql. It does
-- offer call_function, though (see the seoul-weather procedure grant below):
-- an earlier version of this prompt omitted call_function entirely on the
-- assumption this agent would never need it, which meant the model was
-- never actually told the protocol's required "function" field name for that
-- action once seoul-weather granted it a real function to call -- it guessed a
-- plausible key ("name") instead, and every such call was then silently
-- rejected as unpermitted (fn_next_step reads content->>'function', found
-- nothing, and fell through the same path a genuinely unauthorized function
-- name would). Documenting the exact shape here, the same way 'analyst'
-- already does for its own call_function grant, is the fix -- not a
-- permissions change, since the grant itself was already correct.
DO $seed$
DECLARE
  v_agent uuid;
BEGIN
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'general';

  IF v_agent IS NULL THEN
    INSERT INTO allgres_private.agents (agent_id, name)
    VALUES ('ed66eece-f982-4bbb-9c37-0950df6e6bc5', 'general') RETURNING agent_id INTO v_agent;

    UPDATE allgres_private.policies
    SET system_prompt = $prompt$You are a helpful, general-purpose conversational assistant. Reply with one JSON object only. No markdown, no prose.

Allowed:
{"action":"final_answer","answer":"..."}
{"action":"call_function","function":"...","args":{}}
{"action":"await_human","reason":"..."}

Have a normal, friendly conversation. If a procedure you were given names a specific function (for example seoul_weather), use call_function with that exact name in the "function" field and an empty args object, then answer using its result in your own words. When you have a reply, emit final_answer with your answer as plain text.
$prompt$,
        -- Deliberately no llm_config here, same reason as 'analyst' above.
        updated_at = now()
    WHERE agent_id = v_agent;
  END IF;
END
$seed$;

-- A first Procedure / Function pair. The Procedure is reusable prompt
-- policy; seoul_weather is a fixed, reviewed HTTP capability bound to it.
-- Granting this one procedure is sufficient for an agent to use the function.
INSERT INTO allgres_private.procedures (procedure_id, name, content)
VALUES ('a3b48cc2-8a2c-4e55-b71b-26c5d461e5d1', 'seoul-weather', $procedure$When asked about Seoul weather, call the `seoul_weather` function with an empty args object. Read the returned JSON, report the current conditions and temperature in Korean, and say when the source does not contain a requested forecast detail.$procedure$)
ON CONFLICT (name) DO NOTHING;

INSERT INTO allgres_private.functions (function_id, name, description, handler, args_template)
VALUES ('d20c0b28-d197-4e82-959c-3c5254033c8d', 'seoul_weather', 'Fetch current weather and forecast data for Seoul.', 'http_get',
  '{"url":"https://wttr.in/Seoul?format=j1"}'::jsonb)
ON CONFLICT (name) DO NOTHING;

INSERT INTO allgres_private.procedure_function_bindings (procedure_id, function_id)
SELECT p.procedure_id, t.function_id
FROM allgres_private.procedures p, allgres_private.functions t
WHERE p.name = 'seoul-weather' AND t.name = 'seoul_weather'
ON CONFLICT DO NOTHING;

INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
SELECT agent_id, 'procedure', 'seoul-weather'
FROM allgres_private.agents WHERE name = 'general'
ON CONFLICT DO NOTHING;

-- A first, deliberately narrow maintenance/auditor agent (README,
-- "Maintenance agents"): read-only, no mutation surface at all in this
-- slice -- not even propose_change is part of its seeded prompt. It reads
-- v_system_health/v_permission_audit, reports what it finds as its own
-- final_answer (visible in the Sessions thread view like any other run),
-- and remembers anything worth comparing against next time so trends are
-- visible across runs, not just a single snapshot -- the same `remember`
-- action any other agent has, no special case needed. No schedule ships
-- for it; an operator creates one (docs/task-orchestration.md, Schedules)
-- or triggers it (or an external cron hitting POST /api/v1/run), the same
-- as any other agent.
-- The dashboard folds it with System agents (web/index.html isFoldedAgent)
-- so a first-run operator does not see it next to general/analyst as if it
-- were already a conversation agent with a model.
DO $seed$
DECLARE
  v_agent uuid;
BEGIN
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'health_monitor';

  IF v_agent IS NULL THEN
    INSERT INTO allgres_private.agents (agent_id, name)
    VALUES ('52a2d2d7-74d8-4439-81a6-d2159691dd50', 'health_monitor') RETURNING agent_id INTO v_agent;

    UPDATE allgres_private.policies
    SET system_prompt = $prompt$You are Allgres's own health and security monitor. Reply with one JSON object only. No markdown, no prose.

Allowed:
{"action":"final_answer","answer":"..."}
{"action":"execute_sql","sql":"SELECT ..."}
{"action":"remember","content":"...","memory_type":"episodic","importance":0.0-1.0,"subject_id":"system_health"}

You can read exactly two views: allgres_public.v_system_health (worker
counts, queue backlogs, pending approvals, recent failures) and
allgres_public.v_permission_audit (every agent's permission grants).
workers_online counts only backend_type IN ('allgres runtime', 'allgres
web') in pg_stat_activity -- the web worker deliberately never opens a
database connection, so it never appears there, and 1 is the normal
healthy reading with both workers up, not a sign the web worker is down;
0 means the runtime worker itself is down, which is worth flagging. You
cannot change anything -- no propose_change, no delegate, no functions. Your
job is to look, compare against what you remembered last time (it is
already in your own context below, if you have run before), and report:
what changed, anything that looks wrong (a queue backlog that never drains,
an inactive agent that still holds grants, a spike in failed tasks), and
whether it is worth an operator's attention. Remember anything worth
comparing against next run, then give your final_answer as a short summary
a human would actually want to read.
$prompt$,
        max_steps = 6,
        max_retries = 2,
        updated_at = now()
    WHERE agent_id = v_agent;
  END IF;

  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  SELECT v_agent, x.resource_type, x.resource_ref
  FROM (VALUES
    ('view', 'allgres_public.v_system_health'),
    ('view', 'allgres_public.v_permission_audit')
  ) AS x(resource_type, resource_ref)
  ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
END
$seed$;

-- ---------------------------------------------------------------------------
-- 10a-2. The system agent family (item 32/33): one root plus five children,
-- all is_system=true. The root carries no operational job of its own -- it
-- exists so the five children have one place to inherit shared framing and
-- shared grants from (allgres_private.agent_effective_prompt/
-- agent_has_permission walk parent_agent_id up to it); editing the root
-- changes what every child says and may do without editing five rows.
-- Every child's is_system=true means only an admin session may edit its
-- policy/permissions/autonomy from here on (require_admin_for_system_agent,
-- fn_set_agent_autonomy) -- a regular user can see one it is assigned to
-- (My Agents) but never change it. None of these five ships with an
-- llm_config, same as analyst/health_monitor above and for the same reason
-- (ensure_policy's comment): a fresh install must not look like a provider
-- was already picked before an operator actually chose one.
DO $seed$
DECLARE
  v_root uuid;
BEGIN
  SELECT agent_id INTO v_root FROM allgres_private.agents WHERE name = 'system_root';
  IF v_root IS NULL THEN
    INSERT INTO allgres_private.agents (agent_id, name, is_system)
    VALUES ('7ab38d46-72ca-4b94-a6d5-a4431cbe7aef', 'system_root', true) RETURNING agent_id INTO v_root;

    UPDATE allgres_private.policies
    SET system_prompt = $prompt$You are part of Allgres's own system agent family -- built-in agents that
operate the platform itself (this database, its other agents, its own
configuration) rather than a user's workload. You never act alone: every
child agent below adds its own specific job on top of this shared framing.

Reply with one JSON object only. No markdown, no prose. Whatever your
autonomy_level is (visible in your own agent record), never claim an action
took effect before it actually has -- an admin_approval-level action is only
a proposal until decided; a self_approve-level action still means you chose
to act, not that no one is watching; only auto means no human step exists
in the path at all.
$prompt$,
        max_steps = 4,
        updated_at = now()
    WHERE agent_id = v_root;
  END IF;

  -- session_compactor: summarizes a session's older turns once it grows
  -- long, so a long-running Chat/Messenger conversation stays within a
  -- reasonable prompt size without losing what was actually said -- see
  -- fn_maybe_compact_session, the real mechanism this agent's prompt
  -- describes; autonomy_level is 'auto' because its output is additive (a
  -- summary memory placed alongside the untouched, append-only logs, never
  -- a deletion) -- there is nothing here for a human to approve.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'session_compactor') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (agent_id, name, is_system, parent_agent_id, autonomy_level)
      VALUES ('8ce28a6b-cb14-4783-9e55-83a3bc51af29', 'session_compactor', true, v_root, 'auto') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is session compaction. Your task input carries: target_session_id
(what this belongs to), turns (the oldest turns of a long conversation that
no longer fit in a normal context window), and previous_summary (a prior
summary of everything before these turns, or null if this is the first
compaction of this session). On your first step, reply with one JSON
object only: {"action":"remember","content":"<summary>","memory_type":"episodic","importance":0.6,"subject_id":"<target_session_id from your input>"}
where <summary> folds previous_summary (when present) together with turns
into one updated, faithful, dense summary (decisions made, facts
established, open questions) -- short enough to replace all of it in future
context, complete enough that nothing important from either is lost. Never
invent anything not actually in previous_summary or turns. Once remember
succeeds, your next step should give final_answer with a one-line
confirmation -- this task is otherwise done.
$prompt$,
          max_steps = 4,
          updated_at = now()
      WHERE agent_id = v_agent;
    END;
  END IF;

  -- creator: the only agent that may call create_agent (see fn_submit_result's
  -- create_agent branch) -- proposing a brand-new agent (name + prompt) for
  -- a human or its own admin_approval/self_approve setting to let through.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'creator') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (agent_id, name, is_system, parent_agent_id, autonomy_level)
      VALUES ('d372fb6c-9896-488f-b326-c4941dbeaea4', 'creator', true, v_root, 'admin_approval') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is helping build new agents for this platform: turn a plain-language
request ("I want something that watches X and tells me Y") into a concrete
new agent. Reply with one JSON object only:
{"action":"create_agent","name":"...","system_prompt":"...","reason":"..."}
name must be short, lowercase, underscore_separated, and not already in
use. system_prompt must fully specify the new agent's job the same way
every other agent's does: what it reads, what it decides, what its
final_answer should look like -- it will run with zero other permissions
until an admin grants some, so say so in the prompt rather than assuming
access it does not have. Depending on your own autonomy_level this either
takes effect immediately or is queued for an admin to accept or reject --
either way, your job ends at proposing it well.
$prompt$,
          max_steps = 6,
          updated_at = now()
      WHERE agent_id = v_agent;
    END;
  END IF;

  -- fixer: reads what health_monitor already found (same two diagnostic
  -- views) and, instead of only reporting, proposes an actual remediation
  -- for a human (or, at higher autonomy, itself) to let through -- see
  -- fn_submit_result's propose_fix branch and fn_decide_fix.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'fixer') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (agent_id, name, is_system, parent_agent_id, autonomy_level)
      VALUES ('029b7366-3145-440d-99c3-567730551766', 'fixer', true, v_root, 'admin_approval') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is remediation. You can read allgres_public.v_system_health and
allgres_public.v_permission_audit, the same two views health_monitor
watches. When you see something actually wrong (an inactive agent still
holding grants, a queue backlog that never drains, a spike in failed
tasks), propose a concrete, narrow fix. Reply with one JSON object only:
{"action":"propose_fix","fix_kind":"revoke_permission|deactivate_agent","target_agent_id":"...","detail":{...},"reason":"..."}
Never propose anything you cannot fully explain the effect of. If nothing
is actually wrong, use final_answer to say so -- do not manufacture a fix
to have something to propose.
$prompt$,
          max_steps = 6,
          updated_at = now()
      WHERE agent_id = v_agent;
      INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
      SELECT v_agent, x.resource_type, x.resource_ref
      FROM (VALUES
        ('view', 'allgres_public.v_system_health'),
        ('view', 'allgres_public.v_permission_audit')
      ) AS x(resource_type, resource_ref)
      ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
    END;
  END IF;

  -- self_improve: the one agent allowed to propose_change against an agent
  -- other than itself (see fn_submit_result's cross-agent propose_change
  -- extension) -- aimed specifically at cost/efficiency (a shorter prompt,
  -- a cheaper model, a lower max_tokens) backed by this agent's own
  -- execution_logs cost stats, never at what the target agent does.
  -- Roadmap item 7 (evaluation-gated self-improvement): also reads
  -- allgres_public.v_agent_health -- a real completed/failed ratio, not
  -- just cost -- so a change is judged by whether the target got cheaper
  -- *without* the agent actually doing worse afterward, and this agent can
  -- check fn_evaluate_last_change on its own past target before proposing
  -- again, instead of assuming its last proposal already helped.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'self_improve') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (agent_id, name, is_system, parent_agent_id, autonomy_level)
      VALUES ('459920d7-a978-4163-97fe-3f1ba2cc63ff', 'self_improve', true, v_root, 'admin_approval') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is cost efficiency, not behavior. You are given one agent's recent
execution_logs cost stats (steps per task, tokens per step, wall-clock time)
and its current system_prompt/llm_config. Look for waste: a prompt padded
with content that never changes the outcome, a model/max_tokens larger than
the task needs, a step pattern that could be shorter. Before proposing,
execute_sql against allgres_public.v_agent_health for the target agent's
recent_success_rate -- a change that makes it cheaper but noticeably less
successful is not an improvement, do not propose it. If you previously
changed this same agent, you can also check whether that change actually
helped: call the same evaluation this platform already tracks for it
(success_rate_before_last_change on that view, or ask an operator to run
fn_evaluate_last_change) before proposing another change on top of it.
Reply with one JSON object only:
{"action":"propose_change","target_agent_id":"...","changes":{"system_prompt":"...","llm_config":{...}},"reason":"..."}
Never change what the target agent is supposed to accomplish -- only how
cheaply it gets there. If you find nothing worth changing, use final_answer
to say so.

You also own a narrower, function-scoped version of the same idea: any
procedure_function a turn was dispatched through can carry its own model
override, cheaper than whatever the calling agent's own llm_config uses for
its turns in general (see allgres_public.v_function_model_experiments -- read it
with execute_sql). A function with no override yet, or one you think could run
on something cheaper, is a candidate: propose
{"action":"propose_change","target_function_id":"...","op":"start_experiment","candidate_provider":"...","candidate_model":"...","canary_percent":N,"reason":"..."}
to trial it on a small share (canary_percent) of that function's real traffic
without touching the rest. Once a running experiment has at least its
min_sample_size, compare candidate_success_rate against baseline_success_rate
on the same view and propose either
{"action":"propose_change","target_function_id":"...","op":"promote","experiment_id":"...","reason":"..."}
(candidate held up) or the same shape with "op":"reject" (it did not) --
never promote on a smaller sample than min_sample_size, and never propose a
second start_experiment for a function that already has one running.
$prompt$,
          max_steps = 6,
          updated_at = now()
      WHERE agent_id = v_agent;
      INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
      VALUES (v_agent, 'view', 'allgres_public.v_agent_health'),
             (v_agent, 'view', 'allgres_public.v_function_model_experiments')
      ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
    END;
  END IF;

  -- health_monitor already reads v_system_health for the cluster as a
  -- whole; v_agent_health is the same idea per-agent, so it belongs to the
  -- same diagnostic surface -- granted here rather than only at creation
  -- time above, so an existing install picks it up on its next apply too.
  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  SELECT agent_id, 'view', 'allgres_public.v_agent_health'
  FROM allgres_private.agents WHERE name = 'health_monitor'
  ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;

  -- Same "an existing install picks this up too, not just a fresh one"
  -- reasoning as health_monitor's grant just above, for self_improve's own
  -- new function-model-experiment view: the IF NOT EXISTS block only runs the
  -- very first time this agent is created.
  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  SELECT agent_id, 'view', 'allgres_public.v_function_model_experiments'
  FROM allgres_private.agents WHERE name = 'self_improve'
  ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
END
$seed$;

-- Flag everything sections 10-10a-2 created (see 10-0).
SELECT allgres_private.mark_seed_rows();

-- ---------------------------------------------------------------------------
-- 10b. Extension configuration tables -- which of this extension's own
--      tables `pg_dump` includes data for, and on what terms.
--
-- By default `pg_dump` excludes ALL data belonging to an extension's own
-- objects: schema only, regenerated fresh by `CREATE EXTENSION` on restore.
-- Every table below holds real operator/agent state that `CREATE EXTENSION`
-- does not regenerate, so without this a logical backup (`pg_dump`) of this
-- database would restore to a working, EMPTY install -- every agent,
-- session, task, policy, log, and secret silently gone, with no error
-- anywhere to say so. Confirmed live before this was added: a real agent,
-- session, and task, dumped with `pg_dump -Fc` and restored into a fresh
-- cluster, came back with none of it -- only the seed data below. See
-- KNOWN_ISSUES.md, "backup/PITR drill", for the full account and the fix
-- verified afterward. Physical backup (`pg_basebackup` / PITR) has no such
-- gap -- it copies the actual data files -- this is specific to logical
-- (`pg_dump`) backup.
--
-- Tables with no seed rows at all dump unconditionally. The nine tables
-- section 10 seeds (agents, policies, permissions, demo_sales,
-- llm_providers, sql_sandbox_allowlist, functions, procedures,
-- procedure_function_bindings) dump `WHERE NOT is_seed` (see 10-0): the
-- extension script recreates the seed rows fresh on every install, and
-- dumping them too would COPY a second copy on top and fail on the same
-- UNIQUE constraint that makes them idempotent to begin with. The one real
-- cost of that exclusion: an operator's own edit to a seed row (a built-in
-- provider's base_url, is_enabled or allow_private_network, a seed agent's
-- policy/llm_config, the seoul_weather function) does not survive a
-- `pg_dump`-based restore -- only rows the operator created do; a
-- physical backup has no such limit. `sql_function_allowlist` and
-- `oauth_states` are deliberately not registered here: every row in the
-- former is exactly what the extension script itself inserts (see
-- KNOWN_ISSUES, "SQL sandbox function check" -- nothing beyond the seed
-- can exist there today), and the latter holds only short-lived
-- in-progress OAuth flow state that is stale within minutes regardless of
-- backup. `oauth_calls` *is* registered, unconditionally, the same as
-- outbound_calls/sql_calls: unlike oauth_states it is an audit trail of
-- exchange attempts an operator may want to keep, and unlike llm_secrets it
-- never holds a plaintext secret or token to begin with (fn_claim_oauth
-- injects the client secret only into its in-memory response to the
-- worker; fn_complete_oauth never writes a response body back into this
-- table -- there is no response_body column on it at all, only a status
-- code and, on failure, the provider's error text).
-- ---------------------------------------------------------------------------

SELECT pg_catalog.pg_extension_config_dump('allgres_private.agents', 'WHERE NOT is_seed');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.policies', 'WHERE NOT is_seed');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.permissions', 'WHERE NOT is_seed');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.demo_sales', 'WHERE NOT is_seed');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.llm_providers', 'WHERE NOT is_seed');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.sql_sandbox_allowlist', 'WHERE NOT is_seed');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.functions', 'WHERE NOT is_seed');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.procedures', 'WHERE NOT is_seed');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.procedure_function_bindings', 'WHERE NOT is_seed');

SELECT pg_catalog.pg_extension_config_dump('allgres_private.policy_history', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.projects', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.sessions', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.tasks', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.execution_logs', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.human_approvals', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.change_proposals', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.llm_secrets', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.outbound_calls', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.sql_calls', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.oauth_calls', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.oauth_device_sessions', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.agent_memories', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.audit_log', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.api_connections', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.api_connection_secrets', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.procedure_history', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.schedules', '');
-- Real runtime state (which canary experiments ran, and what they decided),
-- not regenerated by CREATE EXTENSION -- the same "a pg_dump of this
-- install must not silently come back empty" reasoning as every other
-- table in this list, and the exact class of bug the backup/PITR drill
-- (KNOWN_ISSUES.md, item 18) already found once for tables missing here.
SELECT pg_catalog.pg_extension_config_dump('allgres_private.model_experiments', '');
-- An operator's own manually-entered price sheet -- exactly the same
-- "real runtime state, not regenerated by CREATE EXTENSION" reasoning as
-- model_experiments just above; nothing seeds this table's rows, so a
-- pg_dump that skipped it would silently come back with every cost_usd
-- unpriced after restore.
SELECT pg_catalog.pg_extension_config_dump('allgres_private.llm_model_prices', '');

SELECT pg_catalog.pg_extension_config_dump('allgres_private.execution_rules', '');

-- ---------------------------------------------------------------------------
-- 10c. Dump coverage for the rest of the user state (C2 coverage). Every
-- allgres_private table is either registered here/above or on the short
-- "not user state" list that fn_selftest's dump_coverage check holds, so a
-- new table that forgets to register fails selftest instead of silently
-- vanishing from a logical dump.
--
-- Registered unconditionally (nothing creates rows here at CREATE EXTENSION
-- time, so a dump never collides with a fresh install):
--   users                      accounts and password hashes: without them no
--                              one can log in after a restore
--   user_agent_assignments, user_agent_chat_sessions,
--   user_agent_preferences, user_project_chat_sessions
--                              which user may use which agent, and which
--                              chat session the user continues
--   channel_messages           the user's own chat messages
--   fix_proposals              pending/decided fixer proposals (human
--                              decisions, like human_approvals above)
--   function_calls, procedure_calls
--                              per-task call history and queued calls, the
--                              same reasoning as outbound_calls/sql_calls
--   function_history           function version history (rollback), the
--                              same as procedure_history/policy_history
--   (agent_groups, agent_group_members, canvas_positions, canvas_templates
--    are registered at the end of sql/canvas.sql, which creates them)
--
-- capability_index is rebuilt for seed sources by CREATE EXTENSION itself
-- (sync_capability_index via the agents/functions/procedures triggers), with
-- fresh random capability_ids, so only rows whose source is not a seed row
-- are dumped, and the three tables keyed on capability_id follow the same
-- filter. History about seed capabilities is lost on a logical restore
-- (the seed-row edit problem, see docs/backup-and-restore.md).
--
-- Deliberately NOT registered (checked by selftest dump_coverage):
--   web_sessions               live login tokens; restoring them would revive
--                              bearer tokens from a backup file. Users log in
--                              again (their accounts restore).
--   oauth_states, sql_function_allowlist
--                              see 10b above
--   provider_probes            "test connection" queue rows and their result;
--                              re-run on demand
--   embedding_calls            the embedding request queue; results live in
--                              capability_index/agent_memories, which are
--                              dumped
--   local_execution_context    per-backend, per-transaction worker context;
--                              meaningless after any restart
-- ---------------------------------------------------------------------------
SELECT pg_catalog.pg_extension_config_dump('allgres_private.users', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.user_agent_assignments', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.user_agent_chat_sessions', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.user_agent_preferences', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.user_project_chat_sessions', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.channel_messages', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.fix_proposals', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.function_calls', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.procedure_calls', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.function_history', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.capability_index',
  'WHERE source_id IS NULL OR source_id NOT IN (SELECT agent_id FROM allgres_private.agents WHERE is_seed UNION ALL SELECT function_id FROM allgres_private.functions WHERE is_seed UNION ALL SELECT procedure_id FROM allgres_private.procedures WHERE is_seed)');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.capability_versions',
  'WHERE capability_id IN (SELECT capability_id FROM allgres_private.capability_index WHERE source_id IS NULL OR source_id NOT IN (SELECT agent_id FROM allgres_private.agents WHERE is_seed UNION ALL SELECT function_id FROM allgres_private.functions WHERE is_seed UNION ALL SELECT procedure_id FROM allgres_private.procedures WHERE is_seed))');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.capability_evaluations',
  'WHERE capability_id IN (SELECT capability_id FROM allgres_private.capability_index WHERE source_id IS NULL OR source_id NOT IN (SELECT agent_id FROM allgres_private.agents WHERE is_seed UNION ALL SELECT function_id FROM allgres_private.functions WHERE is_seed UNION ALL SELECT procedure_id FROM allgres_private.procedures WHERE is_seed))');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.capability_search_events',
  'WHERE selected_capability_id IS NULL OR selected_capability_id IN (SELECT capability_id FROM allgres_private.capability_index WHERE source_id IS NULL OR source_id NOT IN (SELECT agent_id FROM allgres_private.agents WHERE is_seed UNION ALL SELECT function_id FROM allgres_private.functions WHERE is_seed UNION ALL SELECT procedure_id FROM allgres_private.procedures WHERE is_seed))');
