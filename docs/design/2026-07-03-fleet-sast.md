# Design Document: Fleet-wide SAST via "Tatari Org SAST"

**Author:** Scott Idler
**Date:** 2026-07-03
**Status:** In Review (cross-model design review complete, findings folded in)
**Review Passes Completed:** 5/5 + panel (Architect + Staff Engineer)

## Summary

Tatari runs no code-level static analysis (SAST) across its ~300 `tatari-tv`
repos today: the only universal security control is secret scanning (gitleaks),
enforced org-wide as the required workflow "Tatari Org Security". This design
adds a sibling required workflow, **"Tatari Org SAST"**, that runs Semgrep OSS
(plus Checkov for IaC and Trivy for containers) on every pull request in
**non-blocking audit mode** at zero license cost, reusing the exact enforcement
mechanism gitleaks already uses.

## Problem Statement

### Background

The `tatari-tv` org has a working fleet-wide security-gate mechanism:
`github-required-workflows` defines workflows (`security.yaml` = "Tatari Org
Security", `lint.yaml` = "Tatari Org Lint") that GitHub org ruleset **#126206**
("require workflows to pass before merging") forces onto every repo. Public
repos are excluded from that ruleset. "Tatari Org Security" runs
`gitleaks-action` with a licensed `GITLEAKS_LICENSE` secret, so the org already
(a) enforces a security check on every PR and (b) pays for a commercial security
tool. There is no prose "security policy" document: the policy *is* the ruleset
plus these required checks. The Security team (`security@tatari.tv`, #security)
owns this, along with the `security-infra` and `security-operations` repos.

### Problem

A survey of all 329 local `tatari-tv` checkouts found that code SAST is
effectively absent: exactly one repo runs real code SAST (a bespoke Semgrep
ruleset), three run Bandit in pre-commit, and one runs Checkov in CI. Meanwhile
the fleet is Python-dominant (234 repos) with heavy Docker (201), Terraform
(64), and Helm (46) surface, plus JS/TS (21), Rust (19), and Go (5). There is no
systematic detection of injection, unsafe deserialization, SSRF, hardcoded
crypto misuse, IaC misconfiguration, or vulnerable container base images across
the fleet.

### Goals

- Run automated SAST on every PR across all private `tatari-tv` repos.
- Cover the real language mix: Python and JS/TS/Rust code, plus Terraform/Helm
  and container images.
- Zero license cost for the initial rollout (free/OSS tooling only).
- Reuse the existing required-workflows + ruleset enforcement mechanism; do not
  invent new machinery or require per-repo PRs.
- Ship **non-blocking** (audit mode) so a new scanner cannot break every PR on
  day one; make promotion to a blocking gate a one-line change later.
- Surface findings somewhere visible without requiring a paid GitHub SKU.

### Non-Goals

- Buying Semgrep AppSec Platform or GitHub Advanced Security (evaluated as a
  future decision, not this rollout).
- Cross-file / cross-function taint analysis (that is Semgrep's paid Pro engine
  or CodeQL under GHAS).
- A central org-wide findings-triage dashboard with owner routing and SLAs (that
  is precisely what the paid tiers sell; out of scope for the free path).
- Replacing gitleaks / "Tatari Org Security" secret scanning.
- SCA / dependency-vulnerability management as a program (Trivy will surface some
  of it, but dependency governance is a separate effort).

## Proposed Solution

### Overview

Add one new workflow file, `sast.yaml`, to `github-required-workflows`, named
**"Tatari Org SAST"**. It runs three parallel jobs on every PR:

1. **`semgrep`** — Semgrep OSS code SAST (`p/default` + `p/python`).
2. **`checkov`** — IaC misconfiguration (Terraform/Helm/Dockerfile/K8s).
3. **`trivy`** — container image + filesystem SCA + secret scanning.

Every job is **non-blocking**: it carries `continue-on-error: true`, so it may
report findings (and even go red) while the overall workflow run still concludes
`success`. The required-workflows check gates on the
workflow-run conclusion, and a `continue-on-error` job that fails does not fail
the run (verified GitHub behavior), so the merge gate stays green regardless of
findings. The corollary is intentional: while non-blocking, "Tatari Org SAST"
provides visibility, not enforcement — it satisfies the ruleset unconditionally. Findings are delivered via the GitHub
Actions **step summary** (a rendered table per job) and an uploaded **SARIF
artifact** per job. The blocking secret-scan in "Tatari Org Security" is left
untouched.

### Architecture

```
GitHub org ruleset #126206  ── requires ──▶  Tatari Org Security (gitleaks, BLOCKING)
   (private repos)                     └──▶  Tatari Org Lint
                                       └──▶  Tatari Org SAST  ◀── NEW, NON-BLOCKING
                                                 │
                    ┌────────────────────────────┼────────────────────────────┐
                    ▼                             ▼                             ▼
              job: semgrep                  job: checkov                  job: trivy
        (continue-on-error)          (continue-on-error)          (continue-on-error)
                    │                             │                             │
        step summary + SARIF          step summary + SARIF          step summary + SARIF
                    └───────────── workflow run concludes: success ─────────────┘
```

`sast.yaml` lives inline in `github-required-workflows` for v1 (self-contained,
easy to reason about the non-blocking gate during tuning). Extracting the scan
logic into a reusable workflow in `tatari-tv/github-actions`
(`.github/workflows/sast.yml@v5`) with a thin caller here is a deferred
refactor, matching the pattern `security.yaml` already uses for
`tatari-tv/github-actions/checkout@v5`.

### Data Model

The interchange format is **SARIF 2.1.0** (Static Analysis Results Interchange
Format), emitted by all three tools:

- Semgrep: `semgrep scan --sarif --output semgrep.sarif`
- Checkov: `checkov -o sarif --output-file-path .` (writes `results_sarif.sarif`)
- Trivy: `trivy --format sarif`

Each SARIF file is uploaded as a workflow artifact and parsed by a small inline
script to render a Markdown findings table into `$GITHUB_STEP_SUMMARY`
(`runs[].results[]` → rule id, level, `file:line`, message). No database, no
persistent state; the artifact + summary are the record for the free path.

### API Design

Workflow triggers and permissions:

```yaml
on:
  pull_request:
    types: [opened, reopened, synchronize]

permissions:
  contents: read
```

No secrets are required (Semgrep OSS needs no license; community rulesets are
fetched from the public registry). The default `GITHUB_TOKEN` with `contents:
read` is sufficient to check out and upload artifacts.

Non-blocking toggle (the single lever):

```yaml
jobs:
  semgrep:
    continue-on-error: true   # delete this line to make SAST a hard gate
```

### Implementation Plan

#### Phase 1: `semgrep` job (code SAST)
**Model:** sonnet
- A working draft already exists at
  `github-required-workflows/.github/workflows/sast.yaml` (semgrep job only);
  Phase 1 is finishing and validating it.
- `semgrep scan` with the Q4 ruleset set (`p/default` + `p/python` +
  `p/javascript` + `p/typescript` + `p/react` + `p/rust`; `p/secrets` off),
  `--sarif`, `--metrics=off`.
- `continue-on-error: true`; step-summary renderer; SHA-pinned SARIF-artifact
  upload; remove the dead `head_commit` guard.
- Run the **synthetic-failure canary** (YAML error / forced timeout /
  non-continue-on-error job) to prove infra failures are handled, not just
  findings.
- Validate in this repo's own CI (it is excluded from the ruleset, so changes
  are safe to test here) and on 2-3 canary repos of different languages before
  ruleset registration.

#### Phase 2: `checkov` + `trivy` jobs (IaC + container)
**Model:** sonnet
- Add `checkov` job (Checkov over the repo, SARIF out, non-blocking).
- Add `trivy` job (`trivy fs` for SCA/secrets + config scanning, SARIF out,
  non-blocking).
- Same step-summary + artifact pattern. Skip cleanly when a repo has no
  Terraform/Helm/Dockerfile so Python-only repos do not show noise.

#### Phase 3: Fleet registration + rollout comms
**Model:** opus (design/ops judgment; ruleset change is human-approved)
- Register `sast.yaml` in org ruleset #126206's required-workflows list.
- Announce in #security / eng-wide: what it is, that it is non-blocking, where
  findings live, how to suppress false positives (`.semgrepignore`, inline
  `nosemgrep`, Checkov skip comments).
- Establish a baseline noise read across the fleet; tune rulesets down if the
  false-positive rate is high.

#### Phase 4: Evaluate gating + paid tier (decision, not code)
**Model:** opus
- After a soak period, decide per-tool whether to promote to blocking (delete
  `continue-on-error`), and whether findings-management pain justifies paying
  for GHAS Code Security or Semgrep Platform.

## Alternatives Considered

### Alternative 1: Semgrep AppSec Platform (paid)
- **Description:** Semgrep's hosted platform: Pro engine (cross-file taint), Pro
  rules, dedup/triage UI, PR comments, SCA, secrets.
- **Pros:** ~2x detection vs OSS; real org-wide findings management.
- **Cons:** Free tier caps at 10 contributors / 10 repos, so unusable at ~300
  repos without paying; Team tier ~$35/contributor/mo (~$42k/yr at ~100
  committers).
- **Why not chosen:** Cost with no owner yet to action findings. Revisit in
  Phase 4.

### Alternative 2: GitHub Advanced Security — Code Security (paid)
- **Description:** CodeQL code scanning native in the GitHub Security tab, plus
  Copilot Autofix. $30/active committer/mo (split SKU since Apr 2025).
- **Pros:** Native GitHub UI, deep cross-function taint, covers Python/JS/TS and
  Rust (GA Oct 2025), Autofix.
- **Cons:** Cost (~$36k/yr at ~100 committers); required even just to upload
  SARIF to the Security tab on private repos.
- **Why not chosen:** Same as above — the natural paid endpoint later, not the
  zero-cost first step. Free path uses step-summary + artifact instead of the
  Security tab.

### Alternative 3: Per-repo opt-in via `platform-standard-ci.yml`
- **Description:** Add a SAST step to the existing reusable standard-CI workflow;
  repos opt in.
- **Pros:** No ruleset change; repo owners control adoption.
- **Cons:** Opt-in means partial coverage; defeats the "fleet-wide" goal; only
  reaches repos that already call standard CI.
- **Why not chosen:** Coverage is the whole point; required-workflows guarantees
  it.

### Alternative 4: SonarQube / Snyk
- **Description:** Commercial SAST+quality (Sonar) or dev-first SAST+SCA (Snyk).
- **Pros:** Mature dashboards.
- **Cons:** Sonar bills by lines-of-code (expensive across a large private
  fleet); Snyk free tier (100 code tests/period) is far too small for ~300
  repos.
- **Why not chosen:** Cost/fit worse than the Semgrep-or-GHAS choice.

## Technical Considerations

### Dependencies
- Semgrep OSS (LGPL CLI), community rulesets from the public registry
  (`p/default`, `p/python`).
- Checkov, Trivy — both free OSS.
- `tatari-tv/github-actions/checkout@v5` (internal), `actions/upload-artifact`
  (SHA-pinned per repo policy).
- GitHub org ruleset #126206 (existing) — must add the new workflow.

### Performance
- Runs on every PR across ~300 repos. Semgrep OSS is single-file and fast;
  Checkov/Trivy are bounded. `timeout-minutes: 15` per job as a backstop.
- **Actions minutes cost:** three added jobs per PR fleet-wide consumes
  GitHub-hosted runner minutes on the private plan. Quantify against current
  minute usage; consider self-hosted runners or path filters if material.

### Security
- No secrets needed; `contents: read` only, minimizing token blast radius.
- No untrusted PR input is interpolated into any `run:` block (findings are read
  from tool-produced SARIF, not event data), avoiding workflow-injection.
- `--metrics=off` disables Semgrep telemetry; rule fetch is the only network
  egress.
- Trigger is `pull_request` (not `pull_request_target`), so fork PRs run against
  the PR's own code with a read-only token and no secret access — the scanner
  never runs trusted credentials over untrusted code.

### Testing Strategy
- `github-required-workflows` is excluded from ruleset #126206, so `sast.yaml`
  can be exercised by this repo's own CI before it affects anyone.
- Use the `canary` tag pattern from `github-actions` and 2-3 language-diverse
  canary repos to confirm behavior and baseline noise before registration.

### Rollout Plan
- Phase 1-2: build and test in-repo + canary, including the synthetic-failure
  canary from the Risks table. Phase 3: register **Semgrep only** in the ruleset
  first, then add Checkov and Trivy as separate steps once each is baselined
  (do not register all three fleet-wide at once). Phase 4: decide gating/paid
  after soak.

### Rollback / break-glass (required before registration)
Because "Tatari Org SAST" is a required check, a broken `sast.yaml` can block
every PR org-wide — including the PR that fixes it. Before registration:
- Name an **owner authorized to remove `sast.yaml` from ruleset #126206** (or
  disable the rule) without going through a blocked PR.
- Document the **rollback trigger** (any fleet-wide merge block attributable to
  the SAST check) and a **speed target** (minutes, not hours).
- The ruleset toggle is the break-glass, not a code revert: pulling the workflow
  from the ruleset unblocks merges immediately regardless of the workflow's state.

### Measuring the audit
The promotion rubric depends on a fleet-wide false-positive rate, but the free
path has no central dashboard. Decide before Phase 3 which applies:
- **(a)** A lightweight scheduled harvester pulls per-repo SARIF artifacts into a
  store for aggregate FP-rate measurement, or
- **(b)** Accept that "measure then gate" is manual/aspirational until a paid
  console (GHAS Code Security / Semgrep Platform) provides the aggregate view.

This is the crux both reviewers named: without (a) or a paid console, the
promotion criterion cannot be mechanically evaluated.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| **Infra failure hard-blocks every PR fleet-wide.** `continue-on-error` absorbs scanner *findings* but NOT: YAML/syntax errors, runner-provisioning failure, job cancellation, `timeout-minutes` hits, or an inaccessible required-workflow source repo. Any of these fails the run and, as a required check, blocks merges org-wide. | Med | **Critical** | Do NOT rely on continue-on-error for infra safety. Before ruleset registration, run a **synthetic-failure canary** (inject a YAML error, a forced timeout, a non-continue-on-error job) and confirm the gate behavior. Named break-glass owner + documented rollback (below). |
| Alert fatigue / high false-positive rate | High | Med | Ship non-blocking; measure per-language FP rate; document suppression (`nosemgrep`, `checkov:skip=`) before any gating |
| Promotion criterion unmeasurable (no central dashboard on free path) | High | Med | Lock the rubric now (above); decide telemetry-harvester vs manual read under "Measuring the audit" |
| Findings ignored (no owner on free path) | High | Med | Security/AppSec owns audit triage; Phase 4 decides whether to buy a triage console |
| Actions **minutes** cost across ~300 repos | Med | Med | Measure ~2 weeks; in-job runtime skip when no target files (NOT `on: paths:`, ignored for required workflows); hosted runners for v1 |
| Runner **concurrency** spike (3 parallel jobs x ~300 repos can exhaust the enterprise concurrent-runner ceiling and queue PRs fleet-wide) | Med | Med | Distinct from minutes: watch queue depth during rollout; stagger/limit concurrency if it saturates |
| Semgrep hangs / 15-min timeout on huge autogenerated/minified files (and a timeout itself fails the run — see top risk) | Med | Med | Ship a fleet-wide `.semgrepignore` baseline; exclude vendored/generated/minified paths |
| Trivy vuln-DB pull rate-limited across 300 repos | Med | Low | Decide DB caching strategy before Phase 2 |
| Registry/rule fetch flakiness breaks CI | Low | Low | Non-blocking absorbs *findings* flakiness; pin ruleset versions if flaky |
| Rust/JS coverage thin on OSS rules | Med | Low | Audit mode measures it; CodeQL later if Rust/JS depth is needed |

## Design Review: Resolved Decisions

Cross-model design review (Architect = Gemini, Staff Engineer = Codex),
2026-07-03. Both reviewers verified against the repo. Resolutions below; the
correctness issues they raised are folded into the sections above and the Risks
table.

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| Q1 | Inline vs reusable workflow | **Inline in `github-required-workflows` for v1** | Both reviewers agreed: avoid cross-repo versioning + blast radius while tuning; extract to `github-actions` once stable. |
| Q2 | Free path vs buy GHAS up front | **Free path first** | Both: no owner/SLA yet to action findings; ~$36k/yr for a dashboard is premature. Private-repo SARIF-tab requirement re-verified correct. |
| Q3 | Active-committer count | **Use the GitHub Enterprise billing API/UI, not local git** | Local 90-day history covered only ~40 of ~300 repos (125 raw / 117 filtered emails) — undercounts and misattributes; GitHub bills on its own metric. |
| Q4 | Rulesets beyond `p/default`+`p/python` | **Enable `p/python`, `p/javascript`, `p/typescript`, `p/react`, `p/rust` in audit mode; keep `p/secrets` OFF** | Split decision, adjudicated toward Staff: audit mode is exactly when to measure minority-language noise; Python-only contradicts the stated fleet mix. `p/secrets` duplicates the gitleaks channel. Per-language FP rate then gates each ruleset's promotion to blocking. |
| Q5 | Trivy secret scanning | **Disabled** (`--scanners vuln,misconfig`) | Both: gitleaks is the authoritative blocking secret control; a second non-authoritative channel is pure duplicate noise. |
| Q6 | Actions minutes for 3 jobs x ~300 repos | **Stay on hosted runners for v1; skip jobs via in-job runtime file/tool detection; measure ~2 weeks** | Both. **Correction:** workflow-level `on: paths:` filters are IGNORED for required workflows (GitHub docs) — they are NOT a valid minutes mitigation. Skip must be an in-job step after checkout. |
| Q7 | Triage owner + promotion criterion | **Security/AppSec owns audit triage; promote per-tool after soak on objective thresholds** | Both. Rubric locked below rather than deferred to Phase 4. |

### Promotion-to-blocking rubric (locked)

A tool/ruleset moves from non-blocking to blocking only when, over a 30-day
tuning window after a 30-day baseline: false-positive rate is low and stable
(target < 10%), infra-failure rate < 1%, p95 job runtime is acceptable,
suppression syntax is documented, and a named rollback owner exists. Semgrep
high-confidence/high-severity *new* findings are the first candidate to gate;
IaC/container and lower-confidence rules follow per measured noise.

### Still open (do not block Phase 1)
- [ ] Exact FP-rate threshold for gating (Architect proposed <5%/30d, Staff
  <10%): author's call once baseline data exists.
- [ ] Whether to build a lightweight telemetry harvester now vs later (see
  "Measuring the audit" under Rollout).

## References
- `github-required-workflows/.github/workflows/security.yaml` — "Tatari Org
  Security" (gitleaks), the mechanism this mirrors.
- GitHub org ruleset #126206 (require workflows to pass before merging).
- Marquee brief: SAST for Tatari — Exploratory Findings
  (`https://marquee.internal.tatari.dev/p/~scott-idler/sast-for-tatari-exploratory-findings`).
- [Uploading SARIF to GitHub (private repos require Code Security)](https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github)
- Semgrep OSS vs Pro; GHAS split SKUs (Apr 2025); CodeQL Rust GA (Oct 2025).
