# Decision records

Every time a person approves or rejects something, Allgres keeps a record of
the situation, the question as it was asked, and the answer. The records are
written in the shape Laya's official trainer and evaluator read, so that when
you want to teach a [Laya](https://github.com/NandhaKishorM/laya) model your
own judgment, the data is already there and needs no conversion.

PostgreSQL only keeps and hands over the records. It runs no model, and it
does not train or evaluate anything. Training and evaluation use Laya's own
tools (`laya-train`, `laya-evals`) outside PostgreSQL.

Records are written whether or not Laya is connected, because a person's own
decision is the most valuable thing to learn from, and it is lost if it is not
kept when it happens.

## What is kept

A *decision point* is a place where a person picks one answer from a fixed
list. Two exist today:

| Point | Answers | Recorded when |
|---|---|---|
| `approval_decision` | `approve`, `reject` | A person decides an approval request |
| `proposal_decision` | `approve`, `reject` | A person decides a change proposal |

Only a person's decision is recorded. A status something else sets (an
expiry, a system rejection, a stale proposal) is not. The record is written in
the same transaction as the decision; if it cannot be written, the decision
still goes through and an audit entry `decision_records.failed` says why.

Each record holds:

- `state`: the situation, as plain `Label: value` lines. Only the fields the
  point lists in `state_fields` are included, and nothing that can carry a
  secret is read: an approval's arguments and snapshot are never included, a
  URL loses its query string, and a proposal's function body and prompt text
  are summarised by name and description only.
- `questions`: the question exactly as it was asked, with its answers and what
  each means. Changing a question makes a new version; old records keep the
  version they were asked with.
- the answer, who decided and how (`self`, `delegate`, `admin`), and which
  request it came from.
- `split`, `train` or `eval`, fixed when the record is written from a hash of
  the point and the situation, about 10% to `eval`. The same situation always
  lands on the same side, so the evaluation set never shares a situation with
  the training set.

Records and labels are append-only: they cannot be edited or deleted. A
person's own decision gets a `gold` label when it is recorded. To correct an
answer, add another label; the export uses the latest label of the best tier.

## Getting the data out

Over the dashboard API (admin only):

| Action | Purpose |
|---|---|
| `decisions.stats` | Per point: how many records, how many by people, train/eval counts, labels by tier |
| `decisions.export` | JSONL for training or evaluation |
| `decisions.points.list`, `decisions.points.save` | See or change a question (a change makes a new version) |
| `decisions.label.add` | Correct or add an answer for a record already kept |

`decisions.export` takes `split` (`train`, `eval`, or `all`; default `train`),
`point_key`, `tiers` (default `gold` and `silver`), `since`, `until`, `limit`
(up to 50,000) and `offset`. It returns `count`, `sha256`, and `jsonl`. Every
export is logged with its filter, row count, and hash. The same functions are
callable from psql as `allgres_public.fn_decision_*`.

Each line is one record:

```json
{"state": "Approval type: await_human\nReason: Need budget sign-off for ad spend\nAgent: marketing_strategist\nTask goal: Plan Q1 ads",
 "questions": {"approval_decision": {"type": "choice",
   "instructions": "Decide whether to approve this request from an agent to run or continue.",
   "criteria": {"approve": "The request is clear, within what the agent should be doing, and safe to run as described.",
                "reject": "The request is unclear, outside what the agent should be doing, or unsafe as described."}}},
 "expected": {"approval_decision": "approve"}}
```

Train with the `train` split and evaluate with the `eval` split:

```bash
laya-train --data train.jsonl --base english --out ./checkpoint --target-error 0.10
laya-evals run eval.jsonl --model ./checkpoint --min-accuracy 0.8 --max-ece 0.05 --json report.json
```

The export format was checked against Laya's own dataset reader
(`laya.evals.Dataset.from_jsonl`): a sample export parsed cleanly, and a row
whose `expected` named a question it did not carry was refused. Laya needs a
meaningful number of decisions of one kind before a fine-tune is worth
running; see its [fine-tuning guide](https://github.com/NandhaKishorM/laya/blob/main/docs/finetune.md).

## Not here yet

Nothing reads these records to make a decision: using Laya to decide on a
person's behalf is a later stage. There are no screens yet; use the API or
psql. Retention is unlimited, since records cannot be deleted; a purge tool is
not provided.
