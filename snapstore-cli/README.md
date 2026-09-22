# Incremental Snapshot Backup – RL Gym Task

Repository-level software engineering task used to evaluate autonomous coding agents.

## Task Summary

Agents must implement a local, content-addressable incremental backup tool that:

- Creates consistent point-in-time snapshots
- Preserves hard links and sparse files (logical size + allocated blocks)
- Survives abrupt process termination (SIGKILL) without corrupting the repository
- Handles concurrent modification of the source tree during backup
- Supports restore, list, verify and prune with correct referential integrity

The public instruction is deliberately silent on internal architecture; only observable behaviour is specified.

## Layout

```
task/instruction.md     – model-facing problem statement
reference/              – known-good implementation (100 % score)
evaluation/             – hidden black-box tests, scoring, mutants
app-setup/              – build / start / reset lifecycle scripts
package.json            – standard entry points for the evaluation harness
```

## Quick verification

```bash
# Reference must score 1.0
npm run check:reference

# Every mutant must be rejected
npm run check:mutants
```

## Scoring

Weights are defined in `evaluation/scoring.yml` and sum to 1.0.

- core (30 %) – basic backup / restore / list / verify
- advanced (30 %) – hard links, sparse files, prune integrity, corruption detection
- resilience (30 %) – concurrent modification + crash injection
- errors (10 %) – proper error handling

## Model evaluation protocol

1. Give the agent only `task/instruction.md` and a clean workspace.
2. Allow a single generation pass (no interactive debugging).
3. Place the produced code under `solution/`.
4. Run `npm run score`.
5. Both Claude Opus 5 (medium) and GPT-5.6-sol (medium) are expected to finish below 0.30.

Logs and artifacts from those runs belong in `evaluation/proof-of-work/`.
