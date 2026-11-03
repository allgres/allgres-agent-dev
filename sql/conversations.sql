-- One list of conversations (docs/conversations.md).
--
-- General chat, project chat and rooms used to be four separate pages with
-- four separate ways to find "my conversation". Now there is one list. A
-- direct chat is a person talking to one agent; a project chat is the same
-- with a project's prompt and access rules; a room is several people and
-- agents sharing one thread. A person may keep any number of the first two.
-- The messages stay where they were: a chat's thread is its session, a
-- room's thread is its room messages.

-- Remember a conversation that a session already belongs to. Used by the
-- older chat.send / project_chat.send, so what they start also shows up in
-- the list.
CREATE OR REPLACE FUNCTION allgres_private.conv_register(
  p_user_id uuid, p_kind text, p_agent_id uuid, p_project_id uuid, p_session_id uuid, p_title text
) RETURNS uuid
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  -- An empty conversation the person opened first takes the session.
  UPDATE allgres_private.conversations SET session_id = p_session_id, updated_at = now(),
         title = CASE WHEN title = '' THEN left(btrim(COALESCE(p_title, '')), 60) ELSE title END
  WHERE conversation_id = (
    SELECT conversation_id FROM allgres_private.conversations
    WHERE user_id = p_user_id AND kind = p_kind AND agent_id = p_agent_id
      AND project_id IS NOT DISTINCT FROM p_project_id AND session_id IS NULL AND NOT archived
    ORDER BY updated_at DESC LIMIT 1)
  RETURNING conversation_id INTO v_id;
  IF v_id IS NULL THEN
    INSERT INTO allgres_private.conversations (user_id, kind, agent_id, project_id, session_id, title)
    VALUES (p_user_id, p_kind, p_agent_id, p_project_id, p_session_id, left(btrim(COALESCE(p_title, '')), 60))
    ON CONFLICT (user_id, session_id) WHERE session_id IS NOT NULL DO NOTHING
    RETURNING conversation_id INTO v_id;
  END IF;
  RETURN v_id;
END;
$fn$;

-- The thread of a session the way the chat pages show it.
CREATE OR REPLACE FUNCTION allgres_private.session_chat_messages(p_session_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'role', l.role, 'content', allgres_private.chat_display_text(l.role, l.content), 'created_at', l.created_at
    ) ORDER BY l.created_at), '[]'::jsonb)
  FROM allgres_private.execution_logs l
  JOIN allgres_private.tasks t USING (task_id)
  WHERE t.session_id = p_session_id AND t.parent_task_id IS NULL
    AND l.role IN ('user', 'assistant', 'operator')
$fn$;

-- A person's own conversation, or an error. Other people's are never visible,
-- administrators included.
CREATE OR REPLACE FUNCTION allgres_private.conv_own(p_token text, p_conversation_id uuid)
RETURNS allgres_private.conversations
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  c allgres_private.conversations%ROWTYPE;
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL THEN
    RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO c FROM allgres_private.conversations
  WHERE conversation_id = p_conversation_id AND user_id = u.user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'conversation not found' USING ERRCODE = 'P0001';
  END IF;
  RETURN c;
END;
$fn$;

-- Everything the person can talk in, newest first: their own chats and the
-- rooms they are in (administrators see every room, as rooms.list does).
CREATE OR REPLACE FUNCTION allgres_public.fn_conv_list(p_token text, p_limit int DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL THEN
    RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('ok', true, 'conversations', COALESCE((
    SELECT jsonb_agg(to_jsonb(q) ORDER BY q.updated_at DESC)
    FROM (
      SELECT * FROM (
        SELECT c.conversation_id, c.kind, c.title, c.agent_id, a.name AS agent,
               c.project_id, p.name AS project, c.updated_at, NULL::int AS members, NULL::text AS room_status,
               (c.session_id IS NOT NULL AND EXISTS (
                  SELECT 1 FROM allgres_private.tasks k
                  WHERE k.session_id = c.session_id AND k.status NOT IN ('completed', 'failed', 'cancelled'))) AS busy
        FROM allgres_private.conversations c
        JOIN allgres_private.agents a ON a.agent_id = c.agent_id
        LEFT JOIN allgres_private.projects p ON p.project_id = c.project_id
        WHERE c.user_id = u.user_id AND NOT c.archived
        UNION ALL
        SELECT r.room_id, 'room', r.name, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
               COALESCE((SELECT max(x.created_at) FROM allgres_private.room_messages x WHERE x.room_id = r.room_id), r.created_at),
               (SELECT count(*)::int FROM allgres_private.room_members m WHERE m.room_id = r.room_id), r.status,
               EXISTS (SELECT 1 FROM allgres_private.room_turns t JOIN allgres_private.tasks k USING (task_id)
                       WHERE t.room_id = r.room_id AND k.status NOT IN ('completed', 'failed', 'cancelled'))
        FROM allgres_private.rooms r
        WHERE u.role = 'admin' OR EXISTS (
          SELECT 1 FROM allgres_private.room_members m WHERE m.room_id = r.room_id AND m.user_id = u.user_id)
      ) z
      ORDER BY z.updated_at DESC
      LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000)
    ) q), '[]'::jsonb));
END;
$fn$;

-- Open an empty conversation. The session is made with the first message.
-- Asking again for the same agent (and project) while the last one is still
-- empty gives that one back instead of piling up blank rows.
CREATE OR REPLACE FUNCTION allgres_public.fn_conv_new(p_token text, p_agent_id uuid DEFAULT NULL, p_project_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_agent uuid := p_agent_id;
  v_kind text := 'direct';
  v_id uuid;
  v_access record;
BEGIN
  IF p_project_id IS NOT NULL THEN
    SELECT * INTO v_access FROM allgres_private.require_project_access(p_token, p_project_id);
    u := v_access.u;
    v_agent := v_access.agent_id;
    v_kind := 'project';
  ELSE
    IF v_agent IS NULL THEN
      SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'general';
    END IF;
    IF v_agent IS NULL THEN
      RAISE EXCEPTION 'choose an agent' USING ERRCODE = 'P0001';
    END IF;
    u := allgres_private.require_agent_access(p_token, v_agent);
  END IF;

  SELECT conversation_id INTO v_id FROM allgres_private.conversations
  WHERE user_id = u.user_id AND kind = v_kind AND agent_id = v_agent
    AND project_id IS NOT DISTINCT FROM p_project_id AND session_id IS NULL AND NOT archived
  ORDER BY updated_at DESC LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO allgres_private.conversations (user_id, kind, agent_id, project_id)
    VALUES (u.user_id, v_kind, v_agent, p_project_id) RETURNING conversation_id INTO v_id;
    PERFORM allgres_private.audit('conversations.new', jsonb_build_object(
      'conversation_id', v_id, 'user_id', u.user_id, 'agent_id', v_agent, 'project_id', p_project_id));
  ELSE
    UPDATE allgres_private.conversations SET updated_at = now() WHERE conversation_id = v_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'conversation_id', v_id, 'kind', v_kind);
END;
$fn$;

-- Say something. A chat continues its session (the first message makes it);
-- a room takes the message the way rooms.post does.
CREATE OR REPLACE FUNCTION allgres_public.fn_conv_send(p_token text, p_conversation_id uuid, p_message text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  c allgres_private.conversations%ROWTYPE;
  v_msg text := btrim(COALESCE(p_message, ''));
  v_created jsonb;
  v_sid uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM allgres_private.rooms WHERE room_id = p_conversation_id) THEN
    RETURN allgres_public.fn_room_post(p_token, p_conversation_id, p_message);
  END IF;
  c := allgres_private.conv_own(p_token, p_conversation_id);
  IF v_msg = '' THEN
    RAISE EXCEPTION 'message required' USING ERRCODE = 'P0001';
  END IF;
  IF c.archived THEN
    RAISE EXCEPTION 'this conversation is archived' USING ERRCODE = 'P0001';
  END IF;
  -- The same access check every send makes: the agent may have been unassigned since.
  IF c.kind = 'project' THEN
    PERFORM allgres_private.require_project_access(p_token, c.project_id);
  ELSE
    PERFORM allgres_private.require_agent_access(p_token, c.agent_id);
  END IF;

  IF c.session_id IS NULL THEN
    v_created := allgres_public.fn_create_session(c.agent_id, v_msg, c.project_id);
    v_sid := (v_created->>'session_id')::uuid;
    UPDATE allgres_private.conversations
    SET session_id = v_sid, updated_at = now(),
        title = CASE WHEN title = '' THEN left(v_msg, 60) ELSE title END
    WHERE conversation_id = c.conversation_id;
    RETURN jsonb_build_object('ok', true, 'session_id', v_sid, 'task_id', v_created->>'task_id');
  END IF;
  v_created := allgres_public.fn_continue_session(c.session_id, v_msg);
  UPDATE allgres_private.conversations SET updated_at = now() WHERE conversation_id = c.conversation_id;
  RETURN v_created;
END;
$fn$;

-- The thread of a chat. A room's thread is read with rooms.get.
CREATE OR REPLACE FUNCTION allgres_public.fn_conv_history(p_token text, p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  c allgres_private.conversations%ROWTYPE;
BEGIN
  c := allgres_private.conv_own(p_token, p_conversation_id);
  RETURN jsonb_build_object('ok', true, 'kind', c.kind, 'agent_id', c.agent_id, 'project_id', c.project_id,
    'title', c.title, 'session_id', c.session_id,
    'status', (SELECT status FROM allgres_private.sessions WHERE session_id = c.session_id),
    'busy', c.session_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM allgres_private.tasks k
      WHERE k.session_id = c.session_id AND k.status NOT IN ('completed', 'failed', 'cancelled')),
    'messages', CASE WHEN c.session_id IS NULL THEN '[]'::jsonb
                     ELSE allgres_private.session_chat_messages(c.session_id) END);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_conv_rename(p_token text, p_conversation_id uuid, p_title text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  c allgres_private.conversations%ROWTYPE;
BEGIN
  c := allgres_private.conv_own(p_token, p_conversation_id);
  IF length(btrim(COALESCE(p_title, ''))) > 120 THEN
    RAISE EXCEPTION 'title too long' USING ERRCODE = 'P0001';
  END IF;
  UPDATE allgres_private.conversations SET title = btrim(COALESCE(p_title, '')) WHERE conversation_id = c.conversation_id;
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Take a conversation out of the list. Its session is kept, so it still shows
-- under Activity.
CREATE OR REPLACE FUNCTION allgres_public.fn_conv_archive(p_token text, p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  c allgres_private.conversations%ROWTYPE;
BEGIN
  c := allgres_private.conv_own(p_token, p_conversation_id);
  UPDATE allgres_private.conversations SET archived = true WHERE conversation_id = c.conversation_id;
  PERFORM allgres_private.audit('conversations.archive', jsonb_build_object('conversation_id', c.conversation_id, 'user_id', c.user_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Move what already exists into the list. Safe on an empty or an already
-- moved database: it only adds what is missing.
INSERT INTO allgres_private.conversations (user_id, kind, agent_id, session_id, title, created_at, updated_at)
SELECT ucs.user_id, 'direct', ucs.agent_id, ucs.session_id, left(btrim(s.goal), 60), s.started_at, ucs.updated_at
FROM allgres_private.user_agent_chat_sessions ucs
JOIN allgres_private.sessions s ON s.session_id = ucs.session_id
ON CONFLICT (user_id, session_id) WHERE session_id IS NOT NULL DO NOTHING;

INSERT INTO allgres_private.conversations (user_id, kind, agent_id, project_id, session_id, title, created_at, updated_at)
SELECT ups.user_id, 'project', p.agent_id, ups.project_id, ups.session_id, left(btrim(s.goal), 60), s.started_at, ups.updated_at
FROM allgres_private.user_project_chat_sessions ups
JOIN allgres_private.sessions s ON s.session_id = ups.session_id
JOIN allgres_private.projects p ON p.project_id = ups.project_id AND p.agent_id IS NOT NULL
ON CONFLICT (user_id, session_id) WHERE session_id IS NOT NULL DO NOTHING;

-- The shared Team channel becomes an ordinary room that everyone is in.
DO $mig$
DECLARE
  v_room uuid;
  v_name text := 'Team';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.channel_messages)
     OR EXISTS (SELECT 1 FROM allgres_private.rooms WHERE purpose LIKE 'Moved from Team messages%') THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM allgres_private.rooms WHERE name = v_name) THEN
    v_name := 'Team (moved)';
  END IF;
  INSERT INTO allgres_private.rooms (name, purpose, max_turns, max_cost_usd)
  VALUES (v_name, 'Moved from Team messages. Call an agent with @name.', 500, 1000)
  RETURNING room_id INTO v_room;
  INSERT INTO allgres_private.room_members (room_id, user_id)
  SELECT v_room, user_id FROM allgres_private.users ON CONFLICT DO NOTHING;
  INSERT INTO allgres_private.room_members (room_id, agent_id)
  SELECT DISTINCT v_room, x FROM allgres_private.channel_messages m, unnest(m.mentioned_agent_ids) x
  UNION
  SELECT DISTINCT v_room, m.mentioned_agent_id FROM allgres_private.channel_messages m WHERE m.mentioned_agent_id IS NOT NULL
  ON CONFLICT DO NOTHING;
  INSERT INTO allgres_private.room_messages (room_id, author_user_id, kind, content, called_agent_ids, session_id, created_at)
  SELECT v_room, m.author_user_id, 'say', m.content,
         COALESCE(m.mentioned_agent_ids, CASE WHEN m.mentioned_agent_id IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[m.mentioned_agent_id] END),
         m.session_id, m.created_at
  FROM allgres_private.channel_messages m;
  INSERT INTO allgres_private.room_messages (room_id, author_agent_id, kind, content, session_id, created_at)
  SELECT v_room, m.mentioned_agent_id, 'say', left(s.final_answer, 8000), s.session_id, m.created_at + interval '1 millisecond'
  FROM allgres_private.channel_messages m
  JOIN allgres_private.sessions s ON s.session_id = m.session_id
  WHERE m.mentioned_agent_id IS NOT NULL AND COALESCE(s.final_answer, '') <> '';
END
$mig$;
