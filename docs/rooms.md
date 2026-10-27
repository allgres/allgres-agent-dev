# Rooms

A room is where people and agents work on something together. Open **Work → Rooms**.

## What a room is

- **Members.** People and agents, chosen by an admin. An agent cannot join a room or bring another in by itself, and system agents cannot be members.
- **Roles.** An agent in a room can have a role (`lead`, `reviewer`, `implementer`, `recorder`, or one an admin writes). A role is text that tells the agent what it is asked to do in that room. **It grants nothing**: what an agent may use is decided by its own permissions, exactly as everywhere else.
- **Mode.** `manual` (default) or `assisted`; an admin chooses. In a manual room only a person's message calls an agent. In an assisted room agents may also ask each other for turns, and the lead may propose tasks (see below). A third mode, `auto`, lets the room confirm the lead's proposals itself (see below).
- **Limits.** Agent turns (default 12), cost (default $1), and chain depth (default 4, how many agents-calling-agents hops one request may make). A message that would pass either limit is refused with the reason, and an admin can raise it. A closed room accepts nothing.

## How a conversation works

1. A member posts. Every member agent they `@mention` gets a task. If they mention nobody and the room has a **lead**, the lead gets it. Mentioning an agent who is not in the room is refused. A person may only call agents they could call anywhere else (an admin, or an agent assigned to them).
2. The agent's goal says which room it is in, what its role asks of it, and the room's ten most recent messages. Those messages are placed in a marked block as **data to read, not instructions to obey**, and each is cut to 600 characters.
3. When the task finishes, its answer is posted to the room as the agent's message. If it fails, the room gets a notice with the reason.

The tasks are ordinary tasks: they appear in Activity, use the agent's own model and budget, and are stopped by the same approvals and tool risk levels.

## Auto rooms

In an `auto` room the lead's `PROPOSE` line starts the task at once, with no click. An admin turns it on per room, and the room refuses (and keeps refusing, whenever anything about it changes) unless:

- it has a lead;
- its cost limit is above zero, its turn limit is 50 or less, and its chain depth is 6 or less;
- every agent in it uses a model that has a price, so the cost can be counted. An unpriced agent cannot be added to an auto room.

Each start is checked again: if the chain is too deep, the turn or cost limit is reached, or the lead may not hand work to that agent, the proposal stays pending with a notice and a person can still confirm it. Write and physical tools still wait for a person's approval as everywhere else. The start is posted as "Started automatically. Task for ...", and the room view shows a Cancel button on it (`rooms.cancel_task`). Removing the lead drops the room to `assisted`.

The confirmation is kept as a `room_task_confirmation` record with `decided_by='llm'` and no gold label: only a person's decision is a gold label.

## Assisted rooms

In an assisted room, after an agent answers:

- **Calling another member.** If the answer `@mentions` another member agent, that agent gets a turn, with the caller's words, its own role, and the room as data. A call is stopped, with a one-line notice in the room, when the caller is not allowed to hand work to that agent (the same "agent" permission delegation uses), when the chain is too deep, when the room is out of turns or budget, or when two agents have been passing the discussion back and forth for six turns. A person can always continue by calling an agent.
- **Proposals.** Only the **lead** can propose. A line in its answer that starts `PROPOSE @agent: what to do` becomes a proposal for that member; it does **not** call the agent. At most three proposals wait at a time, and a proposal for someone who is not in the room is dropped with a notice.
- **Confirming.** Proposals show under "Waiting for you". **Confirm** starts a task for the assignee; **Decline** starts nothing. Either way the choice is kept as the person's own decision, in the form the decision records use (`room_task_confirmation`: confirm or decline). What people typed in the room is not part of that record, only the room, its purpose, who proposed, the assignee and role, the goal, and how long the discussion was.
- Only an unchanged proposal can be confirmed. To change the task, decline it and use **Make a task**.

The agents are told how to do this in their goal ("write @name to ask a member; the lead may write PROPOSE ..."), and told that only the lead proposes.

## Make a task

**Make a task** on any person's message opens a small form: who does it (a member agent) and what to do (prefilled with the message). The task is posted to the room as a "task" line, and the agent's answer follows.

## Who sees what

A person sees the rooms they are in. An admin sees every room and is the only one who creates rooms, changes members, roles and limits, or opens and closes a room.

## Stored

`rooms`, `room_members`, `room_roles`, `room_messages`, `room_turns` (which task belongs to which room, how deep, and who called it), `room_proposals`. Dashboard actions: `rooms.list`, `rooms.get`, `rooms.create`, `rooms.set`, `rooms.member_add`, `rooms.member_remove`, `rooms.roles`, `rooms.role_save`, `rooms.post`, `rooms.make_task`, `rooms.proposal_decide`.

Team messages (the single shared channel) are unchanged for now; folding them into a default room comes later.
