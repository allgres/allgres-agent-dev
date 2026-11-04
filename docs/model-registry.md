# Providers and their models

**Connections → Models & prices** is one list: each provider, and folded open under it the models it serves, with each model's price beside it.

| Column | Meaning |
| --- | --- |
| Model (checkbox) | On or off. A model that is off cannot be put on agents. |
| Price in / out per 1k | Typed in the row and saved with **Save**; both blank removes it. Only a priced model's calls count toward a cost limit. If the provider reported a price, it is shown under the row with **Use this price**; it is never applied on its own. |
| Used by | Agents, functions and procedures that use it now. |

- **Models are stored.** When a provider is added or edited, it is asked for its models once; what it answers is kept in `llm_models` (source `listed`), so a model can be picked and called without asking again, and nothing needs the provider's *Test connection* first. A model already in the table (switched off, with a note or a price) is left as it is. **Refresh the list** asks again. Every picker (an agent's settings, Chat, My agents) reads this table, and offers only models that are on.
- **Add model** takes a name the provider does not list (a fine-tune, a deployment alias).
- A model an agent already uses is in the list by itself, so nothing that worked before is lost.
- **Use on agents…** puts the model on every ordinary agent or on the ones you tick, and on chosen functions and procedures as their own override. Only the provider and model change; the rest of each agent's setup stays.
- **Remove** is refused while the model is in use (by an agent, a function, a procedure or as the default); switch it off or move them first.
- **Note** and **Settings** are per model.
- A banner lists models that are in use and have no price.
- On upgrade, the lists providers had already reported are moved into the table.

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
