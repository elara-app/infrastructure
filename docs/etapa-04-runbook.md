# Etapa-04 runbook — historical pointer

> **Historical document.** This file is the dated stage-4 verification runbook
> (2026-10-09 snapshot, source-stack specific). It is kept only as a pointer for
> history. Do not run its commands and do not quote its assertions as current.

The current authoritative documentation is:

- [`../README.md`](../README.md) — stack overview, the canonical full-stack command
  block, interfaces and verification targets.
- [`operations.md`](operations.md) — current operational detail: Vault bootstrap,
  Postgres/seed/restart semantics, scaling, environment contract, published
  artifacts, scripts and gotchas.

The stage-4 runbook predates or contradicts current reality in several places, so
its commands are intentionally not repeated here:

- It pins older tooling and jar versions; the repository is at `VERSION 1.3.1`.
- It claims a Vault `mem_limit` of 128M; both stacks use 512M.
- It presents the restart cascade as universal; published has no `restart: true`.
- It says each Postgres container owns both databases; published has one database
  per container and no init script.
- It treats `clone-on-start: false` and the source bind mount as universal;
  published clones GitHub on start (`clone-on-start: true`).
- It predates the published OCI demo artifact, the `smoke-test.sh` and
  `flow-check.sh` scripts, and the current CI publish/smoke workflows.

For anything operational, use `README.md` and `docs/operations.md` instead.
