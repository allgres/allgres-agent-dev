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
