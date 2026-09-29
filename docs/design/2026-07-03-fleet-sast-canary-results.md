# SAST gate canary -- results

Pre-registration evidence for adding `sast.yaml` to org ruleset #126206.
Companion to `2026-07-03-fleet-sast.md`. Question under test: which failure
modes let the required-workflow run conclude `success` (non-blocking, as
designed) vs. which fail/cancel the run and would HARD-BLOCK merges fleet-wide.

## Test bed A -- run conclusion by failure mode

Run as repo-local `on: push` workflows on branch `sast-canary-tests` in
`tatari-tv/github-required-workflows` (excluded from #126206, so zero fleet
risk). Measures the RUN conclusion only; the real required-check gate effect is
test bed C.

| # | Mode | Workflow | Run conclusion | continue-on-error absorbed? | Notes |
|---|------|----------|----------------|------------------------------|-------|
| 1 | scanner finding (guarded, exit 1) | canary-findings | success | yes | intended non-blocking behavior; control |
| 2 | YAML syntax error | canary-yaml-error | failure | n/a (file never parsed) | repo-local still produced a queryable failing run |
| 3 | unresolvable `uses:` (guarded) | canary-bad-uses | success | YES (job conclusion=failure, run=success) | OVERTURNS handoff hypothesis that bad uses fails the run |
| 4 | forced timeout (guarded) | canary-timeout | cancelled | NO | timeout-minutes:1 + sleep 120; step + job + run all cancelled |
| 5 | cancellation | (= mode 4) | cancelled | NO | not directly exercised (gh run cancel blocked by perms); timeout proves a cancel is not absorbed |
| 6 | un-guarded job fails | canary-unguarded | failure | n/a (no guard) | proves the guard is per-job; any future job without the line re-arms blocking |

### Corrected model of `continue-on-error: true`
- Converts a failed step/job into run conclusion `success`. Covers findings (1)
  AND unresolvable-action failures (3).
- Does NOT cover: timeout/cancellation (-> `cancelled`), unparseable YAML
  (-> startup `failure`), or a job that lacks the guard (-> `failure`).

## Open question for test bed C (the decisive one)
Does the required-workflow gate pass/fail on the RUN conclusion, or on
per-job/per-check-run status? Mode 3 concluded run=`success` while its job
went red -- if the gate keys off the run conclusion it is SAFE; if it keys off
the failed job's check run it BLOCKS. Test bed C (real gate on tatari-tv/
sast-canary) settles this, plus confirms modes 2/4/6 actually block.

## Test bed C -- real required-workflow gate

Setup: private throwaway repo `tatari-tv/sast-canary` + org ruleset 18502427
(scoped to `sast-canary` ONLY, no bypass actors, #126206 untouched) requiring
`sast.yaml` from `github-required-workflows`.

### C1 -- findings PR (PR #1), gate confirmed on a real required check
- vuln.py trips Semgrep: log shows `Findings: 3 (3 blocking). Ran 320 rules`.
- BUT the canonical `semgrep scan --sarif --output ...` invocation EXITS 0 on
  findings -> the Scan step + semgrep job conclude `success` (green). Findings
  never even turn the job red. continue-on-error is not exercised by findings.
- All three jobs green, run conclusion = `success`.
- PR: `mergeable=MERGEABLE mergeStateStatus=CLEAN`.
- RESULT: on a real required gate, a success run does NOT block; findings are
  non-blocking (and stronger than assumed -- they don't redden the job at all).

### Check-run vs run conclusion (from test bed A commit)
A `continue-on-error` job that FAILS reports check-run conclusion = `failure`
(observed for both the guarded findings job and the guarded bad-uses job) while
the RUN concludes `success`. So run conclusion and per-job check conclusion
DISAGREE for a guarded crash. Which one the required-workflow gate honors is the
open crux below.

### C2 -- the crux (guarded job CRASHES: run=success, job check=failure) -- RESOLVED
Gate repointed to branch `canary-infra-fail` (guarded semgrep job with an
injected `exit 1`). PR #2 on `sast-canary`:
- Semgrep required check-run = `fail` (the injected crash), Checkov/Trivy = pass.
- Workflow RUN conclusion = `success` (continue-on-error absorbed the crash).
- PR: `mergeable=MERGEABLE mergeStateStatus=CLEAN`.
- VERDICT: the required-workflow gate honors the workflow RUN conclusion, NOT
  the per-job check-run. A guarded job that CRASHES (red job check, run=success)
  does NOT block the merge. continue-on-error protects the gate even on infra
  crashes inside a guarded job. The non-blocking premise HOLDS for anything the
  guard can absorb.

## Decision table (failure mode -> run conclusion -> blocks merge? -> mitigation)
| Failure mode | Run conclusion | Blocks merge? | Mitigation before fleet registration |
|---|---|---|---|
| scanner finding (semgrep exits 0) | success | NO | none -- job stays green |
| step/job crash inside a guarded job (pipx/network/bad-pin) | success | NO (proven C2) | none -- continue-on-error absorbs it |
| YAML/syntax error in sast.yaml | failure (startup) | YES | pre-merge actionlint/yamllint gate on github-required-workflows |
| unresolvable `uses:` in an UN-guarded job | failure | YES | actionlint pin check; keep uses inside guarded jobs |
| timeout | cancelled | YES (run != success) | set an acceptable timeout-minutes; treat cancel as don't-block if feasible |
| cancellation | cancelled | YES (run != success) | operational; rare for a required run |
| job WITHOUT continue-on-error fails | failure | YES | lint asserting every job in sast.yaml carries continue-on-error: true |

Bottom line: blocking is driven purely by RUN conclusion. continue-on-error
makes the run conclude success for any step/job failure it can reach (findings
AND crashes). The residual blockers are the modes the guard cannot cover:
unparseable YAML, timeout/cancel, and any job that lacks the guard. Those are
the fleet-registration MUST-FIXes above.

## Break-glass owner (decided)
Anyone on `@tatari-tv/security` or `@tatari-tv/sre` may pull `sast.yaml` from
ruleset #126206 if it jams merges.

## Cleanup (throwaway artifacts to remove when done)
- org ruleset 18502427 (org change)
- repo `tatari-tv/sast-canary`
- branches `sast-canary-tests`, `canary-infra-fail` in github-required-workflows
