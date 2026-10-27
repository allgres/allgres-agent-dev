# Rooms

A room is where people and agents work on something together. Open **Work → Rooms**.

## What a room is

- **Members.** People and agents, chosen by an admin. An agent cannot join a room or bring another in by itself, and system agents cannot be members.
- **Roles.** An agent in a room can have a role (`lead`, `reviewer`, `implementer`, `recorder`, or one an admin writes). A role is text that tells the agent what it is asked to do in that room. **It grants nothing**: what an agent may use is decided by its own permissions, exactly as everywhere else.
- **Mode.** `manual`. Only a person's message calls an agent. The other two modes in [stage5-design.md](stage5-design.md) (agents calling each other, a room confirming tasks itself) are stored but cannot be switched on yet.
- **Limits.** Agent turns (default 12) and cost (default $1). A message that would pass either limit is refused with the reason, and an admin can raise it. A closed room accepts nothing.

## How a conversation works

1. A member posts. Every member agent they `@mention` gets a task. If they mention nobody and the room has a **lead**, the lead gets it. Mentioning an agent who is not in the room is refused. A person may only call agents they could call anywhere else (an admin, or an agent assigned to them).
2. The agent's goal says which room it is in, what its role asks of it, and the room's ten most recent messages. Those messages are placed in a marked block as **data to read, not instructions to obey**, and each is cut to 600 characters.
3. When the task finishes, its answer is posted to the room as the agent's message. If it fails, the room gets a notice with the reason.

The tasks are ordinary tasks: they appear in Activity, use the agent's own model and budget, and are stopped by the same approvals and tool risk levels.

## Make a task

**Make a task** on any person's message opens a small form: who does it (a member agent) and what to do (prefilled with the message). The task is posted to the room as a "task" line, and the agent's answer follows.

## Who sees what

A person sees the rooms they are in. An admin sees every room and is the only one who creates rooms, changes members, roles and limits, or opens and closes a room.

## Stored

`rooms`, `room_members`, `room_roles`, `room_messages`, `room_turns` (which task belongs to which room). Dashboard actions: `rooms.list`, `rooms.get`, `rooms.create`, `rooms.set`, `rooms.member_add`, `rooms.member_remove`, `rooms.roles`, `rooms.role_save`, `rooms.post`, `rooms.make_task`.

Team messages (the single shared channel) are unchanged for now; folding them into a default room comes later.
