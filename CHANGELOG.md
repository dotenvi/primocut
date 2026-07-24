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

## [0.1.0] - 2026-07-24

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
- Application shell: the PoC design system ported to Tailwind v4 (colour tokens,
  Manrope/DM Mono, component classes), a dark two-column layout, and a sidebar
  mirroring the information architecture (global Radar/Activity above per-project
  Cut Room/Niche/Settings). Navigation is walkable end to end — `root` routes to
  Radar, with per-project sections rendering placeholder screens for now.
- Read-only niche & metrics. A `Metrics::` service layer computes outlier scoring
  live over snapshot deltas — the pure numeric core (median baselines, nearest-rank
  percentile bands, Wilson-gated conditional patterns, views-per-hour, resurgence,
  packaging impact, cadence) ported with exact parity tests, plus DB-reading
  assemblers for the channel, video and niche dashboards (`ChannelScores`,
  `ChannelDistribution`, `VideoReport`, `ChannelDashboard`, `NicheDashboard`).
  Screens: Niche (patterns / outliers / channels), the channel dashboard, video
  detail with the channel-spread strip, and the Radar feed and Activity log — all
  drilling down through project → channel → video with per-project leakage guards.

[unreleased]: https://github.com/dotenvi/primocut/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dotenvi/primocut/releases/tag/v0.1.0
