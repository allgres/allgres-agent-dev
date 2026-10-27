# Handing a decision to the decision model

Everything in Allgres works with people and rules alone. This page is about the one optional step: letting the official **laya-serve** answer a decision point that people answer today. Connect a server first ([decision-models.md](decision-models.md)); then open **Connections → Decision model → Hand decisions to the model**.

Each decision point has its own switch. Nothing is on by default.

| Mode | What happens |
|---|---|
| **Off** | Nothing is asked of the model. |
| **Watch** | After a person decides, the model is asked the same question. Its answer is only compared; nobody sees it before deciding. |
| **Hand over** | A new approval or proposal is put to the model first. A sure answer decides it. Anything else leaves it with a person, exactly as if the model were not there. |

## The steps, as the screen guides them

1. **Watch.** Pick the decision model (and, if you use several, a checkpoint), set how sure the model must be (default 0.80), press *Watch*. The page shows how many decisions were compared and how often the model agreed with the person.
2. **Check.** Handing over needs at least 10 compared decisions and agreement at or above the point's bar (default 80%). Until then *Hand over* is refused with the numbers.
3. **Hand over, for some agents.** Choose the agents whose decisions go to the model, or choose *all agents* on purpose. Others stay with people.
4. **Widen** by adding agents. **Go back** at any time with *Off* for one point, or *Turn everything off* for all; questions still waiting are dropped and the decisions stay with people.

Training and evaluation happen outside Allgres, with `laya-train` and `laya-evals` ([decision-records.md](decision-records.md) has the export). To move a point to a new checkpoint, paste the evaluation report (JSON with `accuracy`, and `ece` if it has one) under *Checkpoints and evaluation reports*, then press *Use this checkpoint*. That is refused unless the report meets the point's bar (accuracy at least the bar, calibration error at most the limit).

## What the model may decide

The rules are the boundary, not the model:

- An approval: the model may **reject** it. It may **approve** one only when an agent is asking a person for judgement. A tool run that needs approval (a write or physical tool, or an unknown outcome) is **only ever approved by a person**.
- A proposal: the model may **reject** it. **Approving** a proposal is always a person's.
- Other decision points (room task confirmation, team assignment) can be watched but not handed over.

## When the model does not decide

These all leave the decision with the person, with the reason shown under *Recent questions*:

- the answer is below the confidence bar (Allgres gates on the server's `answer_confidence`, not on a flag),
- the server is down, slow (2 minutes), or answers an error or something that is not an answer the question offers,
- the rules above do not allow that answer,
- delegation was switched off before the answer arrived, or a person decided first.

Work never waits on the model: an approval that nobody answered stays pending for a person like any other.

## What is kept

A decision the model makes is kept in the same decision records, with `decided_by = 'laya'` and **no gold label** — only a person's decisions are answers to learn from. Watching leaves the comparison in the ask itself (`decision_asks`) and does not add records.

## What was checked

Against a mock that follows the documented request (`POST /v1/systemone`, `state`, `questions`, `min_confidence`, optional `model`) and reply (`answers.<question>.choice`, `answer_confidence`, `abstention`). The documentation does not show a captured reply, so the first run against a real `laya-serve` should be watched: if its reply differs, the parser (`decision_parse_answer`) is the one place to adjust.
