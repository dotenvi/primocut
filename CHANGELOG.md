# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the project is in the `0.y.z` range, the public API is considered
unstable: breaking changes may land in any minor release.

This repository is the Rails 8 rewrite of the Python PoC, whose own history ends
at `0.4.0` in [`dotenvi/primocut-poc`](https://github.com/dotenvi/primocut-poc).
Versioning restarts here at `0.1.0`: the public surface (HTTP routes, CLI, env
vars) is being rebuilt, so continuing the PoC's numbering would imply a
compatibility that does not exist.

## [Unreleased]

### Added

- Repository scaffolding: agent instructions (`AGENTS.md` + `CLAUDE.md`),
  PostgreSQL via `docker-compose.yml`, CI (tests + asset build), and the migration
  plan under `docs/`.
- Competitor-domain data foundation — 12 tables as Rails migrations and models
  (projects, own/competitor channels, competitor videos, channel/video snapshots,
  packaging changes, video attributes/comments/enrichments, and the append-only
  events log). Redesigned idiomatically from the PoC: bigint primary keys with
  `youtube_*_id`, `jsonb` payloads, real foreign keys with cascading deletes, and
  string-backed enums.
