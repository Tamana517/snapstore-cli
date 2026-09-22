# Proof of Work

This directory holds evidence that:

1. The reference solution scores 100 % on the verifier.
2. Two frontier models (Claude Opus 5 medium, GPT-5.6-sol medium) each score below 30 % on a single-pass attempt.
3. Every mutant is detected by `npm run check:mutants`.

## Reference run

```
$ npm run check:reference
...
Passed: 16   Failed: 0
Score: 1.0000
```

(Full log: reference-run.log)

## Model runs

Place the raw agent transcripts, generated solution trees, and scoring output here after the single-pass evaluations.

Expected outcome for both models: score < 0.30.

## Mutant summary

```
$ npm run check:mutants
Mutants caught: 2 / 2
All mutants detected.
```
