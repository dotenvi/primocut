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

- Submit a YouTube video for processing (`SourceVideo`), and the shell-out adapters
  the processing runs on: `Adapters::Ytdlp` (metadata plus audio download normalized
  to 16kHz mono, with a player-client fallback, resume and source cleanup) and
  `Adapters::ChatDownloader` (live-chat replay via `chat_downloader` with a yt-dlp
  fallback, degrading to nothing rather than blocking). `Pipeline::ChatSignals` turns
  a chat replay into per-minute density with laugh/emote counts and z-score peaks.
  These are the building blocks the processing pipeline is assembled from next.
- Transcription over a thin Python sidecar (`sidecar/primocut_engine.py`, driven by
  `Adapters::TranscriptionEngine`): GPU transcription stays in Python (faster-whisper),
  while the rest of the app is Ruby. The transcript is handed back through a file and a
  small JSON status envelope; the sidecar runs in its own process group under a killable
  timeout, so a hung run can never strand a process holding the GPU. It preloads the
  WSL2 pip CUDA libraries and degrades the compute type down the VRAM ladder on its own.
- Process a submitted source video end to end (metadata → audio → transcription → chat),
  run as a background job. Progress is persisted stage by stage for the UI to follow, and
  every artifact is cached: a re-run reuses an existing transcript or chat signal instead
  of downloading and transcribing again. Metadata problems degrade to a warning, a missing
  chat replay is fine, and an essential failure (download or transcription) marks the video
  as errored and raises a Radar alert. Transcription runs one at a time on the GPU queue.
- The Cut Room screen: paste a YouTube link to submit a video for processing, see the
  project's source videos listed with their status, and watch an in-flight video's stage
  and progress update live (the row refreshes itself every couple of seconds until it
  finishes or fails). Everything is scoped to the project.

## [0.2.0] - 2026-07-25

### Added

- Deterministic packaging input (`Metrics::PackagingContext`): a pure read that turns a
  project's niche patterns into the material an AI packaging pass would cite —
  `differential` (the Wilson-gated attributes that separate outliers from the control,
  built with the same primitive the niche view uses so the two never disagree),
  `conventions` (booleans near-universal across the niche — table-stakes, never
  double-counted as a differential), `carries_value` (recurring title names that appear
  disproportionately in outliers, gated by minimum videos and lift), and real outlier
  `examples`. A niche where nothing separates and nothing carries is reported `flat`.
- Opt-in AI comment synthesis (the `comments` kind on `Enrichment::VideoEnricher`, plus
  `Enrichment::Comments` and `Enrichment::AudienceRequests`): reads a video's collected
  comments and records the recurring themes, the audience's explicit requests, and the
  overall sentiment into `video_enrichments`. The model only ever returns a comment
  index — quotes are resolved back to the stored comment and clamped, so it can never
  invent audience words. Keyed by the comment-set hash (paid once per set); a
  `regenerate` re-collects the thread first so a refreshed set re-synthesises. Requests
  aggregate across a project's videos, merging spelling variants and ranking by how many
  videos asked — plain counting, not a second LLM pass.
- Opt-in AI thumbnail enrichment (the `thumbnail` kind on `Enrichment::VideoEnricher`):
  a vision extraction of a thumbnail's visual packaging (faces, expression, overlaid
  text, dominant colours, arrows/highlights, confrontation framing) stored as raw
  output plus code-derived boolean facets in `video_attributes`. The LLM seam attaches
  the fetched image bytes through a short-lived temp file whose format is sniffed from
  the magic bytes. It is cache-gated by the thumbnail byte hash the snapshot cycle
  already maintains — so checking the cache costs no network, and a video whose bytes
  were never hashed is refused with a visible error rather than recharged.
- Opt-in AI title enrichment (`Enrichment::VideoEnricher` + `Enrichment::EnrichJob`),
  built on a provider-agnostic LLM seam (`Adapters::SelectionLlm` over RubyLLM, Claude
  by default). It never runs on a schedule — only from an explicit action — and forces
  a deterministic structured extraction of a title's semantic attributes, storing the
  raw output merged with code-derived boolean facets in `video_attributes`. Every
  result is keyed by a content hash so it is paid for once and shared across projects:
  an unchanged title is a free cache hit, a changed title re-analyses. Per-video
  isolation records a visible error and clears the hash so the next click retries.
- Automatic comment collection (`Competitors::CommentCollection`, wired into the
  snapshot cycle): a consumer of the `outlier_crossed` events, it collects the top
  comments of every definitive outlier still owed them, deterministically and with
  no LLM call. Collect-once by design (the `comments_state` terminal guard stops a
  re-cross from re-collecting); a disabled thread degrades to a terminal `disabled`
  state, while a fetch error stays non-terminal and is retried on a later cycle.
  Each video is isolated so one failure never breaks the cycle, and the comment
  quota folds into the cycle's reported total.
- Outlier-crossing events (`Competitors::OutlierEmission`, wired into the snapshot
  cycle): records an `outlier_crossed` niche event the moment a video steps up to a
  strictly higher band than the one last emitted (persisted per video), so the
  crossing survives a score recompute without flapping. Climbing the ladder
  (relevant → strong → exceptional) emits one event per rung; a video oscillating
  around a cut emits exactly once; provisional crossings carry `provisional=true`.
  Channels are scored in isolation, so one failure never breaks the cycle.
- Competitor snapshot cycle (`Competitors::SnapshotCycle` +
  `Competitors::SnapshotCycleJob`): one collection cycle over the active channels,
  driven by two `config/recurring.yml` cadences — `all` (every video, daily) and
  `recent` (only videos within the recent window, every 6 hours). It records
  channel/video snapshots at one shared instant, detects newly published videos
  and packaging changes (title, and thumbnail by byte hash even under an unchanged
  URL — emitting a `packaging_changed` niche event), then persists the derived
  metrics the data model asks for: syntactic title attributes
  (`Metrics::Attributes.refresh_syntactic_attributes`, content-hash gated) and
  packaging impact once its window elapses (`Metrics::Impact`). Channels are
  processed in isolation (one failure never aborts the cycle; orphaned channels are
  excluded), and each cycle appends a born-resolved `cycle_done` ops record with its
  quota accounting.
- Competitor-channel registration (`Competitors::ChannelRegistration`): resolves
  a URL/handle/ID reference, links it to a project, and enqueues an async backfill
  only when the channel is new to the system (global dedup) or when a known one
  never finished collecting. Cross-project registration only links; an unreachable
  queue leaves the channel in `error` rather than stranded. Detach preserves all
  data and deactivates the channel when it becomes orphaned.
- Channel backfill (`Competitors::Backfill` + `Competitors::ChannelBackfillJob`):
  collects the last N uploads into `competitor_videos` with `is_short` and a
  content-hashed thumbnail, and writes the channel's first channel/video snapshots
  (so dashboards have data before the first scheduled cycle). API/thumbnail
  failures degrade without crashing; the channel snapshot is isolated so its
  failure never costs the uploads. Backfill progress is written incrementally.
- `Thumbnails` helper: SHA-256 of the thumbnail image bytes (injectable fetcher,
  degrades to `""`), and `Competitors::Config` value object for the collection
  knobs (backfill limit, Shorts threshold, recent window).
- YouTube Data API v3 client (`Adapters::YoutubeApi`) for public data, with
  quota accounting (units per operation), batched `videos.list`/`channels.list`
  (50 IDs = 1 unit), paged uploads and top-comment collection, channel-reference
  resolution (URL/handle/ID → a single `channels.list` call, never `search.list`),
  and a permanent/terminal error split (`Error`, `CommentsDisabledError`). The
  HTTP transport is injectable, so the client is exercised without network access.
  The API key is read from `ENV["YOUTUBE_API_KEY"]`.
- Cross-cutting `Resilience` helper: retry policy, exponential backoff (capped),
  and transient-vs-permanent error classification, with an injectable sleeper.
- `dotenv-rails` (development/test) loads a git-ignored `.env`, with a committed
  `.env.example` template documenting the required variables (`YOUTUBE_API_KEY`).

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

[unreleased]: https://github.com/dotenvi/primocut/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/dotenvi/primocut/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dotenvi/primocut/releases/tag/v0.1.0
