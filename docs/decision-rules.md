# Rules for a decision point

A rule is a condition and an outcome, kept as data. For a new approval or proposal the order is **rules → the decision model → a person** ([delegation.md](delegation.md)). Rules work with or without a decision model.

Open **Connections → Decision model → Hand decisions to the model**, pick a point, and open **Rules**. The points that take rules are *An agent asks to run or continue* (approvals), *An agent proposes a change* (proposals), *A room task is confirmed* and the points that functions and procedures declare (below). Team handoffs take none yet.

- **Room tasks.** A rule may *decline* a task or *send it to a person*; it can never confirm one, because confirming starts an agent. A declined task is closed, the room is told which rule declined it, and the decision is kept as a rule's. Only tasks that wait for a person are read: a room set to start tasks by itself starts them before any rule could look.
- **Functions and procedures.** Under *Decision points of functions and procedures* you can declare that a person is asked before one function or procedure runs. It becomes a point of its own, listed under Functions or Procedures with the name and description you give, and a run of it always asks a person, whatever the agent's execution rules say. Its facts and rules are those of approvals (agent, action, resource, …); the model can be watched on it but never hands over (a tool run is only ever approved by a person). Removing the declaration removes its rules and keeps what was decided.

## What a rule says

- **Conditions** about the item: its agent, approval type, action, resource, reason, task goal (approvals) or its agent, proposal kind, target agent, reason (proposals). Each is *field · is / is not / is one of / starts with / contains · text*. Put them under **all of these** or **any of these**. A rule with no condition applies to everything.
- **Outcome**:
  - *approve* or *reject*: the rule decides. The decision is kept as `decided_by = 'rule'` with no gold label (only a person's decisions are answers to learn from), and the reply says which rule decided.
  - *ask the model*: stop reading rules; the model is asked, as if there were no rules.
  - *send to a person*: stop reading rules; nobody but a person decides. The model is not asked.
- **Order.** The first rule that is on and whose conditions hold decides. Use ↑ ↓ to reorder. If none holds, the item goes on to the model (if it is on for the point), then to a person.

Conditions are read by one fixed evaluator; there is no code in a rule. Text is compared exactly (case counts); there are no patterns. A condition about a fact the item does not have does not match.

## A rule that approves is held to more

- It must say **who or what it is about**: an *all of these* list with a condition on an agent, an action or a resource (approvals), or an agent or a kind of proposal (proposals), using *is*, *is one of* or *starts with*. An *any of these* list cannot do that, because the other branch would widen it.
- It is saved only after you **confirm** it. The screen first tries it on past decisions and tells you how many it would have matched and how many had another answer. **Try on past decisions** does that without saving; it reads up to the last 500 decisions people made at the point and writes nothing.
- Turning it on again asks for the same confirmation.
- An unknown outcome of an outbound call is **never approved by a rule**; that stays with a person.
- A rule that decides (approve or reject) needs a condition.

Every save, switch and delete is in the audit log with the conditions.

## When they are read

The worker reads each new item once, within a second or so (it does not wait for a person to open the page). What it did is kept in `decision_rule_checks` (result: applied, to_human, ask_model, none, error). With no enabled rule for a point, nothing changes: the model is asked at once, as before.

## Actions

`delegation.rules`, `delegation.rule_save` (`point_key`, `name`, `conditions`, `outcome`: answer / ask_model / to_human, `answer`, `enabled`, `confirm_approve`), `delegation.rule_set_enabled`, `delegation.rule_delete`, `delegation.rule_move` (`direction`: up / down), `delegation.rule_backtest`. Table: `decision_rules`. All for administrators.

A condition in JSON: `{"all":[{"field":"agent","op":"eq","value":"reporter"},{"field":"resource","op":"starts_with","value":"https://docs.example.com/"}]}`.
