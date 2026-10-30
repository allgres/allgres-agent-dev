# Copying an agent

Open an agent on **Agents** and use **Copy agent** (admin only). The copy is a new agent with its own PostgreSQL role and audit entry. Leave the name empty for `<name>_copy` (then `_copy_2`, …).

| Copied | Not copied |
| --- | --- |
| Prompt, steps, retries, concurrency, turn time, delegation depth, session tasks | Memories |
| Provider and model | Sessions, tasks, schedules |
| Autonomy level, task-model flag, active flag | Inbound event sources |
| Agent config (including function overrides) | Users assigned to the agent |
| Permissions, including who it may delegate to | Rooms; delegations *to* the original |
| Execution rules | |
| Main team and extra teams; Canvas position (moved a little) | |

System agents cannot be copied. RPC: `agents.clone` (`agent_id`, optional `name`).
