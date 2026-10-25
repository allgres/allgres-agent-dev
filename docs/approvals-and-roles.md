# People, roles, and approval routing

Until now an approval request or a change proposal could be decided by any
admin, or by a user assigned to the agent that made it. Nothing said who
*should* decide. This page covers the pieces that do: org units and roles for
people, rules that route a request to a role, an optional escalation to a
second role, and delegation for when someone is away.

Everything here is optional. **With no rule, nothing changes**: a request is
decided exactly as before. Roles never grant anything beyond "may decide the
requests routed to this role".

## The pieces

| Piece | What it is |
|---|---|
| Unit | A department or team of people. Units nest. Example: Marketing, with Growth under it. |
| Role | A name for a responsibility. Example: Marketing head, Legal reviewer. |
| Membership | One fact: this person holds this role, in this unit (or anywhere, when no unit is given). A person can hold several. |
| Rule | Routes requests to a role. Matches by request type, and optionally by the Canvas group the requesting agent sits in. |
| Delegation | "While I am away, let her decide in my place", for a bounded time. |

A unit is not a Canvas group. Groups arrange agents; units arrange people.

## Rules

A rule applies to approvals or to change proposals, and says who decides.

- **Matches.** `match_kind` narrows by type. For approvals it is `await_human` (an
  agent asked a person), `execution` (an execution rule requires approval), or
  `outbound_unknown` (an outbound call whose result is unknown). For proposals
  it is the proposal kind, such as `create_function` or `policy_change`.
  `match_agent_group_id` narrows to agents in that Canvas group or one below it.
  Leave either empty to match all.
- **Decider.** `decider_role_id`, and optionally `decider_unit_id`: when a unit is
  named, only a holder of the role *in that unit* may decide.
- **Escalation.** `escalate_after_seconds` and `escalate_role_id`, set together.
  Once the time has passed with no decision, holders of the second role may
  decide as well.
- **Order.** The lowest `priority` number is tried first. At equal priority a
  rule that names a group beats one that does not, then one that names a kind.

The rule is applied once, when the request is created, and its result is stored
on the request. Changing or deleting a rule later does not move requests that
are already waiting. Deleting a role deletes the rules that name it; a request
already routed to it can then only be decided by an admin.

## Who may decide

| Request | May decide | May only see |
|---|---|---|
| Not routed | An admin; a user assigned to the agent (for a proposal, only a `policy_change` for an agent they are assigned to) | |
| Routed | An admin; a holder of the routed role (in the routed unit, if one is set); after the escalation time, a holder of the escalation role; anyone those people delegated to while the delegation is active | The user assigned to the agent |

The last column is deliberate: a rule cannot be walked around by the person it
routes around. An admin can always decide.

## Using it

**In the dashboard.** The Approvals page has a **Mine / All I can see** toggle
on the Approvals and Proposals tabs: *Mine* is what you may decide. A routed
request shows who it is routed to and when it opens to the second role, and if
you may not decide it the buttons are replaced by a note saying who can. Admins
manage rules, roles, units, who holds which role, and delegation on the
**People** page (under Organization), and get a **Decisions** tab on Approvals,
described in [decision-records.md](decision-records.md).

**Over the dashboard API** (admin only):

| Action | Purpose |
|---|---|
| `org.state` | Units, roles, memberships, rules, and delegations in one reply |
| `org.units.save`, `org.units.delete` | Create, rename, or move a unit; delete one |
| `org.roles.save`, `org.roles.delete` | Create or rename a role; delete one |
| `org.memberships.add`, `org.memberships.remove` | Give or take a role (`user_id`, `role_id`, optional `unit_id`) |
| `approval_rules.save`, `approval_rules.delete` | Create or change a rule (`rule` object), or delete one |
| `approval_delegations.add`, `approval_delegations.remove` | Delegate between two users until `valid_until` |

`approvals.list` and `proposals.list` accept `mine: true` to list only what the
caller may decide, and every row carries `routed_role`, `escalate_at`, and
`can_decide`. `approvals.decide` and `proposals.decide` check the table above
and record who decided (`decided_by_user_id`) and how (`self`, `delegate`, or
`admin`).

The same functions are callable from psql as `allgres_public.fn_org_*`; each one
writes an audit row.

## Example

Marketing's approvals go to the Marketing head, and to the CEO after a day:

```sql
SELECT allgres_public.fn_org_save_role(NULL, 'Marketing head');
SELECT allgres_public.fn_org_save_role(NULL, 'CEO');
SELECT allgres_public.fn_org_save_unit(NULL, 'Marketing');
-- then add memberships, and:
SELECT allgres_public.fn_org_save_rule(jsonb_build_object(
  'name', 'Marketing approvals', 'applies_to', 'approval',
  'match_agent_group_id', '<marketing group id>',
  'decider_role_id', '<Marketing head id>', 'decider_unit_id', '<Marketing unit id>',
  'escalate_after_seconds', 86400, 'escalate_role_id', '<CEO id>'));
```

## Not here yet

Users cannot delegate their own authority themselves; an admin sets
delegations. A rule can match by request type and Canvas group only, not by the
amount or other details of a request. See [stage1-design.md](stage1-design.md)
for what comes next.
