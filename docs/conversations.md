# Conversations: one list

General chat, project chat, the Team channel and rooms used to be four tabs with four ways to find "my conversation". They are now one list on the **Chat** page, in the style of a chat app: the list is on the left, the thread of the chosen one on the right.

## What is in the list

| Kind | What it is | Thread |
|---|---|---|
| chat | You and one agent (`general` by default). Keep as many as you like. | the agent's session |
| project chat | A chat that belongs to a project: the project's instructions and access rules apply. | the agent's session |
| room | Several people and several agents in one thread (docs/rooms.md). | the room's messages |

A **New chat** starts a chat with `general`. **More…** lets you pick another agent, a project, or (administrators) a room. The first message names a chat; **Rename** changes the name, **Archive** takes it out of the list (its session stays, so it still shows under Activity).

The agent list in **More…** is the agents assigned to you. A project chat needs the project's agent to be assigned to you too, as before.

Conversations are private to their owner, administrators included. Rooms are listed for their members; an administrator sees every room, as before.

## What did not change

- Where messages live. A chat's thread is its session (`execution_logs`); a room's thread is `room_messages`. Rooms still run each call as its own task with the room's thread in the goal, and keep their limits (turns, cost, depth), lead, roles, modes and proposals. Merging the two message stores would change what an agent sees, so it was left alone.
- The older actions `chat.send`, `chat.history`, `chat.new`, `project_chat.send`, `project_chat.history`, `messenger.post` and `messenger.list` still work. What `chat.send` and `project_chat.send` start also appears in the list. The Canvas chat uses `chat.*`.

## Actions

| Action | Does |
|---|---|
| `conv.list` | your chats and your rooms, newest first (`kind` is `direct`, `project` or `room`; a room's `conversation_id` is its room id) |
| `conv.new` | `agent_id` or `project_id`; opens an empty chat (an empty one for the same agent is reused) |
| `conv.send` | `conversation_id`, `message`; the first message makes the session; for a room it posts like `rooms.post` |
| `conv.history` | the thread of a chat, with `busy` while an agent is answering; read a room with `rooms.get` |
| `conv.rename`, `conv.archive` | as named |

New table `conversations` (chats and project chats only; rooms are not copied into it).

## Upgrading

On a database that already has chats, the first start adds them to the list: each person's General and project chat, and the Team channel, which becomes a room named **Team** with every account in it and the old messages (and each agent's last answer) in it. Nothing is deleted: the old tables stay, and a new database has nothing to move. People added after the move are not in the **Team** room until an administrator adds them.

The **Rooms** and **Team messages** tabs are gone; a saved link to Rooms opens Chat.
