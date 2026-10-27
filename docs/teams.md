# Teams: second teams, a window for handed-over work, shared notes

Open **Teams** (admin). Design: [stage5-design.md](stage5-design.md).

## A second team

An agent keeps its **first team** (set on the Canvas). Add further teams on the Teams page. A second team opens only two things: the way work reaches the agent through that team's window, and the shared notes of that team. What the agent may do and who answers for its cost stay with its first team and its own grants. System agents cannot join a team. Removing an agent from a team clears a window that relied on it.

## A team's window

A team can take work from others in one of two ways:

- **An agent takes it.** Every handoff starts a task for that agent.
- **A person picks who.** The handoff waits under *Waiting for you*; an admin gives it to an agent in the team or says nobody takes it. The pick is kept as the person's own decision, with a gold label. Its question is one per team (`team_assign_<id>`); its answers are that team's agents as they are now, plus `decline`. A change in the team makes a new version of the question.

The work runs as the agent that takes it, never as the sender, so a sender gets no more than that agent may do. A person hands work over from the Teams page (`teams.handoff`). An agent hands work over with `fn_team_handoff_by_agent`; it needs a grant of type `agent` with the reference `team:<team name>` (the same kind of grant as delegating to an agent). Agents in the first release hand work to an agent-window team by delegating to that agent.

What the task finishes with is written back to the handoff, so **Handed over** shows who sent it, which team, who took it, how it is going, and the result.

## Shared notes

Notes belong to a team or to the organization. An agent reads them as data, in a marked block of its prompt, a few per place, most important first.

| | read | write |
|---|---|---|
| Agent's own memory | itself | itself |
| Team notes | members of the team (first or second team) | an agent with a grant |
| Organization notes | an agent with a grant | an agent with a grant |

An agent saves a shared note with `remember` and `"scope":"team"` (optionally `"team":"<name>"`) or `"scope":"org"`. People add and delete notes on the Teams page. Grants are set in the same place.

## Not done yet

- The Canvas does not draw second teams as dotted lines; they show on the Teams page.
- A room's summary is not saved as a team note automatically.
