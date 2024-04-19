# Tatari Organization GitHub Required Workflows

GitHub Actions Workflows designed to be run and required to pass on all `tatari-tv` organization repositories.

[Documentation](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-workflows-to-pass-before-merging)

## Required Status Checks

A PR in this repo must be able to run all GitHub Actions workflows before it can be merged, as they will affect the Tatari organization repositories. This repo is excluded from the GitHub oragnization ruleset so that we can test any changes to these workflows as part of this repo's CI (as we do in other repositoryies).
