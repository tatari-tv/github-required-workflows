# Tatari Organization GitHub Required Workflows

GitHub Actions workflows required to pass on all `tatari-tv` organization repositories via org-level ruleset 126206.

[Documentation](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-workflows-to-pass-before-merging)

## Workflows

| Workflow | Purpose |
|----------|---------|
| `security.yaml` | Runs gitleaks secret scanning on all PRs |

## Source repo visibility

This repo is **public** so that the org ruleset can require workflows from it against any target — including public repos. GitHub requires a required-workflow source to be at least as visible as its targets.

Any `uses:` references inside required workflows must also point at public actions.

## Contributing

Changes to required workflows affect all org repositories. Open a PR; the SRE team (`@tatari-tv/sre`) reviews and merges.
