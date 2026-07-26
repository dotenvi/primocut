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

- The Radar feed now shows what actually happened: each card names the competitor
  video behind the event, with its thumbnail, band tag (p90/p97/p99), the project
  badges of the channel that published it, the view/median metrics and the
  channel-spread strip. Cards open the video report.
- "Mark all as seen" clears the Radar feed, and each of its two feeds (New,
  Earlier) pages independently.
- Open operational failures surface above the Radar feed as a "Needs you" band.
- The video screen's back link points at where the screen was opened from.
  Arriving from the Radar (or the niche outlier ranking) returns you to that
  screen, at the feed page, filter and format you left it on; reached any other
  way, or directly, the link still walks up the hierarchy to the channel.

- The Activity log now reads as a log: each row names the job, the subject it
  acted on, the API quota it spent and whether it succeeded, under a day
  separator, with the total quota accounted in the header. It pages backwards
  through the whole history instead of stopping at the newest hundred.

### Fixed

- Tables render with the design system's rules and column headers again. The
  port dropped the `td`/`th` styling, so every table in the app (Niche, Channels,
  Activity) fell back to the browser's bare cells.
- The Activity quota read "—" while the cycle events it is summed from were
  already in the log. The sidebar reads the same accounting against the budget it
  resets to, over the API's quota day — which turns over at midnight Pacific, not
  at the app's midnight, and is the only window in which "used / budget" means
  anything.
- The sidebar stopped issuing one channel COUNT per project on every page render.
- Radar cards no longer render as empty rows. They read `payload["title"]`, which
  no event has ever carried — titles, channels and thumbnails are resolved from
  the subjects the event references.
- The Radar project filter now scopes through the project's tracked channels. It
  compared `events.project_id`, which is always null for a niche event (a channel
  can belong to several projects), so filtering yielded an empty feed.
- `rake primocut:doctor` no longer reports NVENC as unavailable when it actually
  works. The probe encoded a frame too small for NVENC on ffmpeg 7.x (rejected with
  "-22 Invalid argument"), producing a false negative; it now encodes a valid tiny
  clip.

## [0.5.0] - 2026-07-25

### Added

- `bin/primocut`, a command-line tool for driving the app from the terminal
  (testing workflows, not product flows). It boots the full app and exposes four
  commands: `pipeline URL --project N` runs the source-video pipeline inline
  (metadata → audio → transcription → chat), reusing the cached transcript on a
  re-run; `snapshot` runs one competitor snapshot cycle without the scheduler;
  `metrics` prints a niche, channel or video dashboard as JSON (for numeric parity
  checks); and `export --cut N` packages a cut into a deliverable bundle.
- `rake primocut:doctor`, an environment check that validates the GPU/CUDA (WSL2),
  FFmpeg (and the optional NVENC encoder), yt-dlp, the Python transcription sidecar,
  the LLM key, the YouTube Data API key and the database. It prints a colour-coded
  table and, for every failure, the command that fixes it, exiting non-zero when the
  environment is not ready.

## [0.4.0] - 2026-07-25

### Added

- The Cut Room, per source video — first section: triage its AI topics. Open a
  processed video's Cut Room from the sources list, run (or regenerate) the topic
  analysis, and watch the topics appear live while the pass runs (the panel refreshes
  itself until it finishes). Each topic shows its time range, clip-potential score and
  summary, and can be kept, discarded, or reopened — an opinion that persists across
  sessions. Everything is scoped to the project.
- The Cut Room — second section: compose the cut and render its clips. Add a topic
  (its range snapshotted) or a manual time range to the cut, reorder the items, and
  remove them; then render the clips in the background and watch each item's state
  move from queued through cutting to rendered (or errored) live as the render runs.
- The Cut Room — third section: export the cut. Package the rendered clips into a
  bundle (optionally skipping the master or upscaling it to 1440p), watch the build
  status live, and download the finished zip. Export needs at least one rendered clip.
- The Cut Room — fourth section: opt-in AI packaging. Generate per-clip titles and
  thumbnail briefs, extract and rank candidate thumbnail frames, and match the niche's
  audience requests to the cut's topics — each from its own button, with the results
  (titles, brief summary, best frame, audience match) appearing live per item as the
  passes run. Every pass is cached, so re-running is cheap.
- Opt-in AI packaging for a cut's clips (`Cuts::PackagingService`, four explicit
  actions): propose titles and a thumbnail brief per clip — each grounded only in the
  niche's measured packaging patterns, with any citation the code cannot match back
  dropped rather than invented; extract candidate thumbnail frames deterministically
  (no AI); rank those frames against the brief with a vision pass; and match the
  niche's audience requests to the source video's topics (cached, and skipped
  entirely when there is no demand). Each pass is per-item isolated and paid for once
  by a content hash over the clip and the patterns that shaped it.
- Break a source video's transcript into topics with AI (`Cuts::Selection` +
  `AnalyzeTopicsJob`): a long transcript is windowed with overlap and each window is
  segmented into macro topics by the LLM, which returns segment indices (never
  invented timestamps) that the code resolves into real seconds. Window-overlap
  duplicates are consolidated, and a window that fails permanently keeps whatever was
  already found rather than losing the pass. Each topic can be triaged per source
  video (`Cuts::Triage` — keep as "maybe", "discard", or clear back to open),
  persisted across sessions; regenerating the topics replaces the set and drops stale
  triage.
- Export a cut into a deliverable bundle (`Cuts::Export` + `CutExportJob`): the cut's
  rendered clips are copied (never moved) into a timestamped package, each with a
  clip-relative `.srt` cut from the transcript, alongside a concatenated master (a
  fast stream copy by default, or an opt-in 1440p re-encode) and both a machine
  `manifest.json` and a human `manifest.md` with clickable timestamps back into the
  source video — then zipped. Un-rendered items fail the export with a clear message
  by default, or can be rendered first on request.
- Render a cut's clips in the background (`Cuts::Render` + `CutRenderJob`): each item
  downloads only its section and re-encodes to a frame-exact MP4, with per-item
  isolation (one clip that fails is flagged with its error and the rest still render)
  and a pay-once cache (an unchanged item is skipped, and a pure reorder just renames
  the file — no re-encode). Clips land under `clips/<video>/<cut>/NNN-slug.mp4` and are
  deliverables, never swept. An optional boundary-refinement seam nudges a clip's cut
  points to the nearest word edge when an align backend is configured.
- The clip-render building blocks (`Adapters::Ffmpeg`, plus `download_section` on
  `Adapters::Ytdlp`): download only the section around a cut (exact-cut keyframes so
  audio and video stay in sync), fine-cut it into a frame-exact MP4 re-encode (NVENC
  with an automatic libx264 fallback, or an opt-in keyframe-imprecise stream copy),
  and extract deterministic candidate frames from a clip (scene changes first, then
  evenly-spaced samples, pay-once by presence). `Cuts::Naming` turns a clip's title
  into its `NNN-slug.mp4` filename. These are the pieces the render step runs on next.
- The data model the Cut Room is built on: a source video's transcript is broken into
  `Topic` segments, each triaged per source video (`TopicTriage` — keep as "maybe" or
  "discard"); the topics and manual ranges the user keeps are composed, in order, into
  named `Cut`s of `CutItem`s. Every item renders to one `Clip` (an MP4 deliverable, with
  a pay-once cache key over its range, padding and encode profile), a whole cut exports
  to one bundle (`Export`), and each item can carry opt-in AI packaging (`CutPackaging` —
  titles, thumbnail briefs, frame ranking) plus a per-source-video `AudienceMatch`. These
  are the tables the rendering, export and packaging steps are assembled on next.

## [0.3.0] - 2026-07-25

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

[unreleased]: https://github.com/dotenvi/primocut/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/dotenvi/primocut/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/dotenvi/primocut/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/dotenvi/primocut/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/dotenvi/primocut/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dotenvi/primocut/releases/tag/v0.1.0
