# Models by provider

**Connections → Models & prices** lists each chat provider as a section that folds open to its models.

| Column | Meaning |
| --- | --- |
| Model (checkbox) | On or off. A model that is off cannot be put on agents. |
| Price in / out per 1k | From the price sheet; only a priced model's calls count toward a cost limit. |
| Used by | Agents, functions and procedures that use it now. |

- **Add model** takes a name, or pick from what the provider lists (run *Test connection* on the provider first). *Add all listed* adds everything it lists.
- A model an agent already uses is in the list by itself, so nothing that worked before is lost.
- **Use on agents…** puts the model on every ordinary agent or on the ones you tick, and on chosen functions and procedures as their own override. Only the provider and model change; the rest of each agent's policy stays. System agents are never touched. What each one had before is kept in the audit entry (`models.apply`). *Also make it the model new agents start with* sets the default for agents created later; it is never a hidden fallback at run time.
- **Remove** is refused while the model is in use (by an agent, a function, a procedure or as the default); switch it off or move them first.
- **Price** and **Note** are per model.

Actions: `models.registry`, `models.registry_add`, `models.registry_set`, `models.registry_remove`, `models.apply`, `models.targets`, `models.clear_overrides`, `models.default_clear`. Table: `llm_models` (provider, model, on/off, note, default settings).

## Models an agent may use

In an agent's settings (**Agents → Edit → Models this agent may use**) tick the models it may use. Tick none and any model that is switched on is allowed.

- The agent's own model, a person's choice in General (*My model*) and a model picked for one task must be among the ticked ones.
- A function or procedure's own override and a model experiment are the administrator's choice and are not held to the list.
- A model switched off in Models & prices is refused for everyone.
- An agent whose model cannot be used shows the reason in the Agents list and in its settings, and its turns fail with that reason instead of calling the model: no model chosen, the provider or the model is off, or the model is not among the ticked ones.

Action: `agents.set_allowed_models` (`agent_id`, `models`: a list of `{provider, model}`). Table: `agent_models`.

## Inference settings

Set on an agent (**Agents → Edit → Reasoning and sampling**) or as a model's defaults (**Models & prices → Settings**). Order: the agent's value, then the model's default, then the server's own default.

| Setting | OpenAI-compatible | Claude |
|---|---|---|
| Effort (low, medium, high, xhigh, max) | `reasoning_effort` (xhigh and max become high) | `output_config.effort` |
| Thinking (adaptive, enabled + budget, disabled; display summarized or omitted) | not used | `thinking` |
| Temperature, top P, top K | sent | not sent (rejected by current Claude models) |
| Max tokens | sent | sent, 4096 when blank |
| Stop sequences | `stop` | `stop_sequences` |

A blank setting is not sent. Values are checked when saved (temperature 0 to 2, top P above 0 up to 1, thinking budget at least 1024, up to 16 stop sequences). Stored in `agents.llm_config` and `llm_models.params`.
