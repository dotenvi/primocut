# PRIMOCUT — Migration Plan: Python/FastAPI/Svelte → Rails 8

## Context

PRIMOCUT is a working PoC built as a Python monolith: a FastAPI web API, a Svelte 5
SPA, an RQ worker, an rq-scheduler process and a Typer CLI, all sharing one pipeline
core (`pipeline.py::run_stages`) over SQLite + Redis. See `docs/COMPONENTES.md` for
the full component map of the current system.

**Why migrate.** The primary driver is **learning Rails 8** on a real, non-trivial
codebase the author already understands end to end. The PoC is feature-rich enough
to exercise the whole framework (models, controllers, views, jobs, recurring tasks,
file handling, external adapters), which makes it good learning material.

**Intended outcome.** A Rails 8 application owning everything except the parts that
are genuinely bound to Python ML libraries, with:

- **Rails 8** + **Hotwire** + **Tailwind CSS** replacing FastAPI + Svelte
- **PostgreSQL** replacing SQLite
- **Solid Queue** replacing RQ **and** rq-scheduler **and** Redis
- **RubyLLM** replacing the hand-rolled multi-provider LLM client
- A thin **Python sidecar** (~584 LOC) retained only for transcription

### Decisions already made

| Decision | Choice | Rationale |
|---|---|---|
| Python boundary | Sidecar CLI, JSON contract | Only transcription is truly Python-bound |
| Migration strategy | Strangler fig, domain by domain | System stays usable; small, repeatable learning loops |
| Database | PostgreSQL | `jsonb` for 10+ payload columns, write concurrency, Rails default |
| Schema | Idiomatic redesign + data migration | Avoids inheriting PoC conventions; teaches ActiveRecord properly |
| Queue | Solid Queue (via ActiveJob) | Rails 8 default; removes Redis entirely |
| GPU lock | Dedicated queue, concurrency 1 | Portable across backends; mirrors today's `gpu.py` semantics |
| Metrics computation | Ruby (POROs), SQL only if measured slow | Matches today's design; keeps the database swappable (§2.5) |
| Error handling | Domain exceptions, caught at the right level | Idiomatic Rails; mirrors the current resilience model (§2.6) |
| Realtime | Polling first, partials everywhere | Turbo Streams adopted later as a deliberate experiment |
| CLI | Kept, as Thor/rake | Used for testing, not for product flows |

---

## 1. What stays in Python, and why

An audit of every third-party import and `requirements.txt` entry classified the
codebase into three groups.

### 1.1 Genuinely Python-bound — **584 LOC**

| File | LOC | Dependency |
|---|---|---|
| `transcription/faster_whisper_engine.py` | 183 | faster-whisper (CTranslate2 + CUDA) |
| `transcription/whisperx_engine.py` | 153 | whisperx |
| `transcription/engine.py` | 26 | (protocol) |
| `render/align.py` | 179 | whisperx word alignment |
| `render/align_worker.py` | 43 | whisperx (already a subprocess) |

This is the **entire** Python surface that survives.

### 1.2 Python packages that do **not** require Python glue

- **yt-dlp** — already invoked as a subprocess, not as a library:
  `YTDLP = [sys.executable, "-m", "yt_dlp"]` (`download/audio.py:25`,
  `render/section.py:35`). Ruby shells out to the `yt-dlp` binary identically.
- **chat-downloader** — currently used as a library (`chat/downloader.py:21`), but
  the package ships a CLI that emits JSON. Becomes a shell-out like the others.
- **FFmpeg / NVENC** — already pure `subprocess`. The whole `render/` package
  (865 LOC) is FFmpeg orchestration and ports to Ruby almost 1:1.

### 1.3 Replaced by Rails equivalents

`typer`/`rich` → Thor · `pydantic`/`pydantic-settings` → Rails config + credentials ·
`anthropic` → RubyLLM · `fastapi`/`uvicorn` → Rails · `rq`/`rq-scheduler`/`redis` →
Solid Queue · `sqlalchemy` → ActiveRecord.

### 1.4 The sidecar contract

The pattern already exists in the codebase: `render/align_worker.py` is a subprocess
in a separate venv, with a JSON contract and a killable timeout. Generalize it into
one thin binary:

```
primocut-engine transcribe --audio PATH --language pt --model large-v3-turbo --out OUT.json
primocut-engine align      --audio PATH --segments IN.json --out OUT.json
primocut-engine doctor     --json
```

Rules: stdout is **JSON only** (logs go to stderr), non-zero exit means failure with
a JSON error body, and every invocation is killable by timeout. Ruby never imports
Python — it only runs a process and reads a file.

---

## 2. Target architecture

### 2.1 Processes

| Today | Tomorrow |
|---|---|
| `primocut serve` (FastAPI + SPA) | `bin/rails server` |
| `primocut worker` (RQ) | `bin/jobs` (Solid Queue, default queues) |
| — | `bin/jobs --queue gpu` (concurrency **1** — the GPU lock) |
| `primocut scheduler` (rq-scheduler) | **gone** → Solid Queue recurring tasks (`config/recurring.yml`) |
| `primocut <admin>` (Typer) | `bin/primocut` (Thor) + rake tasks |
| Redis | **gone** |

> Solid Queue has built-in recurring tasks, so the whole `scheduler` process
> disappears — the daily `all` and 6-hourly `recent` snapshot cycles become two
> entries in `config/recurring.yml`.

### 2.2 Responsibility layering

This is the core of the refactor. The current code mixes concerns (`cli.py` holds
three roles; `worker/queue.py` is an enqueue god-module). The Rails app enforces a
strict layering instead:

```
app/
  models/          ActiveRecord: persistence, associations, scopes, validations.
                   No orchestration, no external calls.
  services/        Domain operations, grouped BY DOMAIN (not by technical type).
                   Plain Ruby objects. This is where the real logic lives.
  jobs/            ActiveJob: thin. Parse args → call a service → report progress.
                   Never contains business logic.
  adapters/        The outside world, one class per external dependency.
                   Swappable and fakeable in tests.
  controllers/     Thin: params → service → render. No logic.
  views/           ERB + Hotwire. Everything is a partial (see §2.7).
```

**Services, by domain** — mirrors the domains that already exist in the PoC:

| Namespace | Replaces | Responsibility |
|---|---|---|
| `Pipeline::` | `pipeline.py`, `worker/jobs.py` | Stage orchestration for a live |
| `Competitors::` | `worker/snapshot_jobs.py`, `channel_jobs.py`, `channels.py`, `event_emission.py`, `comment_collection.py` | Channel registration, snapshot cycles, event emission |
| `Metrics::` | `metrics/` (2219 LOC) | Outlier scoring, bands, patterns, impact — computed on read |
| `Cuts::` | `worker/render_jobs.py`, `export_jobs.py`, `packaging_jobs.py` | Render, export, packaging |
| `Enrichment::` | `worker/enrich_jobs.py`, `metrics/enrichment.py` | Opt-in LLM enrichment |

**Adapters, one per external dependency:**

| Adapter | Wraps | Replaces |
|---|---|---|
| `Adapters::Ytdlp` | `yt-dlp` binary | `download/audio.py`, `render/section.py` |
| `Adapters::Ffmpeg` | `ffmpeg`/`ffprobe` | `render/encode.py`, `frames.py`, `package.py` |
| `Adapters::TranscriptionEngine` | `primocut-engine` sidecar | `transcription/` |
| `Adapters::YoutubeApi` | YouTube Data API (Faraday) | `youtube/client.py` |
| `Adapters::Llm` | RubyLLM | `analysis/llm.py` |
| `Adapters::ChatDownloader` | `chat_downloader` CLI | `chat/downloader.py` |

### 2.3 Preserve the two invariants

The PoC has two rules that must survive the port — they are the reason it works:

1. **One pipeline core.** `run_stages` is the only place the stage order exists.
   In Rails this becomes `Pipeline::Runner`, called by **both** the job and the CLI.
   The `Store`/`ProgressReporter` injection seam becomes a **`reporter` argument**:
   `Pipeline::DbReporter` (writes progress rows) vs. `Pipeline::LogReporter` (CLI).
   Persistence is always ActiveRecord. **Never duplicate stage logic.**

2. **The golden rule of analysis.** The LLM returns segment **indices**, never
   timestamps; index→time resolution is clamped to real segments
   (`models.py::resolve_span`). This ports to a `Analysis::SpanResolver` and must be
   the only path from model output to time. See the RubyLLM risk in §5.

### 2.4 Design principles (calibrated, not dogmatic)

The PoC **already practices dependency inversion**: 51 injection points
(`metadata_fn`, `download_audio_fn`, `store`, `reporter`, `engine`, `llm`,
`gpu_lock`, `thumbnail_fetcher`, …) and 9 fake classes in the test suite, which runs
with no GPU and no network. **This is the single most valuable property to carry
over.** It is not a new discipline to learn — it is one not to lose.

**SOLID, weighted for this codebase:**

| | Weight | Applied to |
|---|---|---|
| **SRP** | **High** | The direct cure for `cli.py` (3 roles) and `worker/queue.py` (enqueue god-module). One service = one domain operation. |
| **OCP** | Low | No speculative extension points. Open a class when the *second real* case arrives. |
| **LSP** | Medium | Adapters. Already present: `TranscriptionEngine` is a protocol with two interchangeable implementations. |
| **ISP** | Medium | The reporter seam. `ProgressReporter` is minimal, which is why both implementations are trivial. |
| **DIP** | **High** | Already practiced. Port it as constructor injection with sensible defaults. |

**Conventions:**

- Services expose **one public method** (`call`); dependencies arrive through the
  constructor with real defaults, so production code reads clean and tests inject
  fakes.
- **Comments explain *why*, never *what*.** The existing docstrings are mostly the
  valuable kind — e.g. `worker/event_emission.py` explains why `outlier_crossed`
  only fires on a transition to a strictly higher band. Delete narration; **preserve
  rationale**. Losing those comments would re-introduce solved bugs.
- **DRY under KISS.** Duplication is cheaper than the wrong abstraction. Abstract on
  the third repetition *that shares a reason to change*, not the second.
- No Repository pattern over ActiveRecord (§2.5). No Result objects by default (§2.6).

### 2.5 Database abstraction: bounded blast radius, not zero cost

**ActiveRecord is already the database abstraction.** Adding a Repository layer on
top of it duplicates a framework abstraction — the definition of over-engineering.

Portability is achieved by a design choice instead: **computation lives in Ruby, the
database only stores.** This matches what the PoC already does — percentile math runs
in application code today (`metrics/core.py:166`, `nearest_rank_percentile` sorts
lists in Python), not in SQL. Keeping that:

- `Metrics::` services are POROs, tested without a database;
- SQL stays portable (plain `SELECT` + indexes);
- Postgres is still the right choice — `jsonb`, write concurrency, Rails default —
  but it does not lock the project in.

If a dashboard ever proves slow under real volume, **that one query** moves into a
query object with database-specific SQL. Coupling is then introduced **by decision
and in one visible place**, never by accident. The goal is not a free database swap
(that is a fiction); it is a known, small, greppable set of files to change.

### 2.6 Error handling: exceptions, caught at the right level

Domain exceptions, in a small hierarchy — idiomatic Rails, and it composes with
ActiveRecord, which raises. Result objects are **not** adopted by default: they add
ceremony at every call site and require wrapping every AR call. They fit failures
that are expected, branching business outcomes; PRIMOCUT's failures (network down,
video removed, FFmpeg crashed, queue unreachable) are genuinely exceptional.

There is **one** error model; only the catch point changes with context — exactly
the model the PoC already uses:

- **Request path** — failure is terminal for the request → catch at the boundary
  (`rescue_from` → 404/422). Mirrors today's `KeyError → 404`,
  `QueueUnavailableError`, `VideoBusyError`.
- **Batch jobs** — failure is *data about one item* → catch per item, persist
  `state: :error` with the message, continue the batch. Mirrors today's per-item
  isolation in `worker/render_jobs.py` and `worker/enrich_jobs.py`.

### 2.7 Views: partials first

Every view is composed of partials from day one, because **a partial is the unit
that both polling and broadcasting share**. Start with the current behavior (Turbo
Frames with `refresh`, matching today's ~2s polling). Later, switching a screen to
Turbo Streams means adding `broadcast_replace_to` in the job — **with no change to
the view**. This makes the realtime comparison a controlled experiment rather than a
rewrite.

---

## 3. Schema redesign

25 tables move from SQLite to PostgreSQL with Rails conventions applied:

- **Primary keys**: `videos.id` is currently the YouTube ID (string). Becomes
  `id: bigint` + `youtube_id: string` with a unique index. Same for
  `competitor_channels` (`UC…`) and `competitor_videos`.
- **JSON → `jsonb`** for all 10+ payload columns (`events.payload`,
  `jobs.warnings`, `jobs.stage_history`, `transcripts.segments`,
  `chat_signals.per_minute`/`peaks`, `video_attributes.attributes`, …), with GIN
  indexes where queried.
- **Real foreign keys + associations** replacing implicit joins, so
  `belongs_to`/`has_many` work without workarounds.
- **Timestamps**: `created_at`/`updated_at` everywhere.
- **Hand-written SQL migrations** (`db/migrations/002…010`) become Rails migrations;
  the migration history is *not* replayed — the redesigned schema is the new
  baseline.

### The strangler consequence (important)

Redesigning the schema means Rails and Python **cannot share a database**. The
strangler therefore runs as **parallel systems with independent databases**, not as
a shared-DB proxy:

- The Python app keeps running, untouched, on its SQLite.
- A **re-runnable, idempotent importer** (`rake primocut:import_legacy`) reads the
  SQLite file and populates Postgres.
- Re-run the importer whenever you want fresh data in Rails, until cutover.
- Cutover is per domain: once a domain works in Rails, stop using it in Python.

This is viable specifically because PRIMOCUT is a **single-user personal PoC** —
there is no concurrent write traffic to reconcile.

---

## 4. Migration phases

Ordered so each phase is independently useful, and difficulty ramps up as Rails
familiarity grows.

### Phase 0 — De-risking spikes (do these first)

Small throwaway experiments that de-risk the three unknowns before committing:

1. ~~**RubyLLM forced tool use**~~ — **DONE, passed.** See §5.1 for results.
2. ~~**Python sidecar**~~ — **DONE, passed.** See §5.2 for results.
3. ~~**Solid Queue long job**~~ — **DONE, passed.** See §5.3 for results.

### Phase 1 — Foundation

- `rails new` (Rails 8, Postgres, Tailwind, Propshaft, Solid Queue).
- Full schema as Rails migrations (§3); ActiveRecord models with associations,
  scopes and validations.
- `rake primocut:import_legacy` — the idempotent SQLite → Postgres importer.
- Layout, navigation and the Tailwind design system, matching the current IA
  (Radar/Activity global, above per-project Lives/Niche/Settings).

**Learning focus:** migrations, associations, scopes.

### Phase 2 — Niche & metrics (read-only slice)

The safest first slice: **pure reads, no jobs, no external calls.**

- Port `metrics/` (2219 LOC) to `Metrics::` service objects — scoring, band ruler,
  percentiles, patterns, impact. Straight algorithm translation, easy to test.
- Controllers + Hotwire views for Radar, Activity, Niche (patterns/outliers/channels),
  Channel dashboard, Video detail.
- Reference: `metrics/service.py` already assembles the exact dashboard payloads.

**Learning focus:** ActiveRecord queries, controllers, views, Tailwind.

### Phase 3 — Competitor collection (jobs + recurring)

- `Adapters::YoutubeApi` (quota accounting preserved).
- `Competitors::SnapshotCycle` as an ActiveJob; the daily `all` and 6-hourly `recent`
  cadences become **`config/recurring.yml`** entries — the scheduler process is gone.
- Port event emission (including the `outlier_crossed` anti-flapping guard, which
  depends on `last_band_emitted`) and comment collection.
- Channel registration + backfill.

**Learning focus:** ActiveJob, Solid Queue, recurring tasks, HTTP adapters.

### Phase 4 — Lives pipeline (the sidecar boundary)

- `Adapters::Ytdlp`, `Adapters::ChatDownloader`; chat z-score in Ruby
  (`chat/signals.py` is small and pure).
- `Adapters::TranscriptionEngine` → the Python sidecar, on the `gpu` queue.
- `Pipeline::Runner` — the single stage core, with the reporter seam (§2.3).
- Lives list + submission + live progress UI.

**Learning focus:** shell-out adapters, job orchestration, progress reporting.

### Phase 5 — Cut Room (largest surface)

- `Adapters::Ffmpeg`; port `render/` (865 LOC) — section download, encode, frames,
  package/export. Mostly mechanical.
- `Cuts::` services: render (per-item isolation + `params_hash` pay-once cache),
  export (clips + SRT + concat master + manifests), packaging (titles, thumbnail
  briefs, frame extraction, vision ranking, audience match) via RubyLLM.
- Cut Room UI — the biggest UI unit (`CutRoom.svelte`, 764 LOC) rebuilt in Hotwire.

**Learning focus:** complex forms, nested resources, file downloads, Turbo.

### Phase 6 — CLI, cutover, decommission

- `bin/primocut` (Thor) for the testing workflows you actually use, plus rake tasks;
  `doctor` becomes a rake task validating GPU, FFmpeg, yt-dlp, sidecar, LLM key, DB.
- Delete the Python app except the sidecar; drop Redis; archive `frontend/`.
- Update `AGENTS.md`, `README.md`, `docs/DEVELOPMENT.md`, `docs/COMPONENTES.md`.

---

## 5. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| ~~RubyLLM may not support *forced* tool use~~ | — | **RESOLVED** by the Phase 0 spike — see §5.1. |
| Solid Queue is younger than Sidekiq for multi-hour jobs | Job loss or timeout surprises | Phase 0 spike; transcription is an external, killable process; ActiveJob keeps the Sidekiq escape hatch at one config line |
| Schema redesign blocks a shared-DB strangler | Divergent data during migration | Idempotent re-runnable importer; single-user PoC makes this safe (§3) |
| `metrics/` port introduces subtle numeric drift | Wrong outlier bands, silently | Port the Python test suite's fixtures as Rails test fixtures; compare both systems' output on the same imported dataset |
| Cut Room is the largest single unit | Phase 5 stalls | It is deliberately last, when Rails/Hotwire fluency is highest |

### 5.1 Spike result — RubyLLM forced tool use (**passed**)

Run against the real Anthropic API with `claude-sonnet-5`, RubyLLM 1.16.0, Ruby 4.0.1.

**Forced tool use is supported.** `chat.with_tool(tool, choice: :tool_name)` maps to
Anthropic's `tool_choice: {type: "tool", name: …}` — the exact mechanism
`analysis/llm.py` relies on. Valid choices are `:auto`, `:none`, `:required`, or a
specific tool name.

**The schema pins the types.** A `params` block declaring `integer :start_index`
returned Ruby `Integer`s in every case — **including an adversarial prompt** that
explicitly demanded `MM:SS` timestamps and a paragraph of prose first. The tool
schema won over the instruction.

**`Tool::Halt` keeps it to one round trip.** Returning `RubyLLM::Tool::Halt` from
`execute` stops the agentic loop, so structured extraction costs **one** API call
(message trace: `user → assistant[tool_call] → tool`, 1 assistant turn) — cost parity
with the current Python implementation.

**What the spike did NOT prove.** An attempt to induce out-of-range indices (asking
for 6 topics over a 7-segment transcript while suggesting indices like 20/50/99) was
**resisted by the model** — it returned valid indices. This is reassuring but is
**not a guarantee**: JSON Schema `integer` carries no range constraint, so nothing
structurally prevents a hallucinated index. **`Analysis::SpanResolver` must keep
clamping to real segments and remain the final authority**, exactly as
`models.py::resolve_span` does today.

**Two operational findings:**

- **The bundled model registry goes stale.** `claude-sonnet-5` was unknown to
  RubyLLM 1.16.0 and raised `ModelNotFoundError`; `RubyLLM.models.refresh!` (which
  fetches from the provider) fixed it. A clean production install will hit this —
  refresh on boot, or persist a registry with `save_to_json` and version it.
- **`temperature` is deprecated on `claude-sonnet-5`.** RubyLLM forwards it and the
  API rejects the request with `BadRequestError`. Do not call `with_temperature` for
  this model.

Reference implementation shape for `Adapters::Llm`:

```ruby
class SelectTopics < RubyLLM::Tool
  description "Return the macro topics found in the transcript."
  params do
    array :topics, required: true do
      object do
        string  :title,       required: true
        integer :start_index, required: true
        integer :end_index,   required: true
      end
    end
  end

  attr_reader :captured

  def execute(topics:)
    @captured = topics
    RubyLLM::Tool::Halt.new("captured")   # one round trip
  end
end
```

### 5.2 Spike result — Python sidecar boundary (**passed**)

Ruby 4.0.1 driving the project venv (Python 3.13.5, faster-whisper 1.2.1) on an
RTX 3070 Ti under WSL2, with the real `large-v3-turbo` model.

| Test | Result |
|---|---|
| `doctor` → JSON envelope | pass |
| `transcribe` → real GPU run driven from Ruby | pass — model load 3.59s, total 4.23s |
| Timeout kills the **process group** | pass — `nvidia-smi` compute processes before=0 after=0, **no orphan** |
| Structured error propagation (missing audio) | pass — non-zero exit + `{"error": …}` → `TranscriptionError` |
| 500 lines of stderr noise | pass — stdout JSON uncorrupted |

**The finding that matters.** The first run **failed** with
`Library libcublas.so.12 is not found or cannot be loaded` — even though the libs
were present in the venv and the model loaded fine when invoked directly. The cause
is `_preload_cuda_libs()` in `transcription/faster_whisper_engine.py:20`: under WSL2
the CUDA runtime arrives via pip and is **not** on `LD_LIBRARY_PATH`, so the libs
must be loaded `RTLD_GLOBAL` with `ctypes` before ctranslate2 can resolve them by
soname. A naive port silently loses this and the sidecar cannot use the GPU at all.

Two consequences for the plan:

1. **The sidecar owns its CUDA environment.** The Rails process must never need CUDA
   env vars — porting `_preload_cuda_libs` into the sidecar entry point is mandatory,
   not optional.
2. **Generalize the lesson.** This is exactly the kind of hard-won production
   knowledge that lives in the `why` comments (§2.4). When porting any module, read
   the rationale comments first — they encode failures already paid for.

**Contract decisions validated:**

- **Payload goes to `--out FILE`, not stdout.** A 4h transcript is megabytes of JSON;
  a pipe risks blocking if the reader does not drain it. stdout carries only a small
  status envelope.
- **Ruby must drain stdout/stderr in threads** and spawn with `pgroup: true`, killing
  with `Process.kill("-KILL", pgid)`. Killing only the parent would strand a CUDA
  process holding the GPU — the exact failure today's `gpu.py` lock exists to avoid.

**Not validated:** transcription *quality* — the spike used synthetic audio (1
segment). Faster-whisper itself is unchanged production code; what was new, and is
now proven, is the boundary.

### 5.3 Spike result — Solid Queue (**passed**)

Rails 8.1.3, Ruby 4.0.1. Timings compressed (`process_alive_threshold` 10s instead of
the 5min default, heartbeat 2s) so the staleness behaviour is observable in seconds.

| Test | Result |
|---|---|
| Long job vs. staleness — 30s job under a 10s alive threshold | pass — **executed exactly once**, no duplicate |
| `gpu` queue, `threads: 1` — 3 jobs | pass — strictly sequential, same PID, no overlap |
| Progress read from **another process** while the job runs | pass — 20→40→60→80→100% |
| Recurring tasks (`config/recurring.yml`, `every 5 seconds`) | pass — 4 fires in 20s, on schedule |

**The main risk did not materialize.** A job running 3× longer than the
alive-threshold was *not* considered dead and re-enqueued — Solid Queue's heartbeat
runs on its own thread, independent of job execution. This matters because a
duplicated transcription would mean two processes competing for one GPU.

**The GPU lock is just queue configuration.** A `gpu` queue with `threads: 1,
processes: 1` in `config/queue.yml` serializes execution exactly like today's Redis
lock in `gpu.py` — no lock code to write, and portable to Sidekiq if ever needed:

```yaml
workers:
  - queues: "default"
    threads: 3
  - queues: "gpu"        # one transcription at a time (replaces gpu.py)
    threads: 1
    processes: 1
```

**The scheduler process is confirmed gone.** `config/recurring.yml` fired on schedule
and persisted into `solid_queue_recurring_tasks`. The daily `all` and 6-hourly
`recent` cycles become two YAML entries — `primocut scheduler` and `rq-scheduler`
both disappear.

**Rails 8 ships Solid Queue by default.** `rails new` generated `config/queue.yml`,
`config/recurring.yml`, `db/queue_schema.rb` and `bin/jobs` with no extra gem. It is
production-only out of the box; development needs
`config.active_job.queue_adapter = :solid_queue` plus a `queue` database entry and
`config.solid_queue.connects_to`.

**Caveats — what this spike did NOT prove:**

- **Ran on SQLite, not PostgreSQL.** Postgres is **not installed** on this machine
  (no `psql`, and no `libpq-dev`, so the `pg` gem cannot build). Solid Queue's job
  lifecycle is backend-independent, so these results carry over — but Postgres
  write-concurrency under a real worker+web load remains unverified. Installing
  Postgres and `libpq-dev` is a Phase 1 prerequisite.
- **Compressed timings, not a real long run.** The mechanism is proven; a genuine
  multi-hour transcription under default thresholds has not been executed.

---

## 6. Verification

**Per phase:**

- **Rails tests** for every service object ported, using fakes for adapters — the
  current suite already proves this design works (it needs no GPU and no network).
- **Numeric parity** for Phase 2: run `primocut metrics show --project N` (Python)
  and the Rails equivalent over the same imported data; diff the JSON. Band
  thresholds, percentiles and outlier verdicts must match exactly.
- **Pipeline parity** for Phase 4: process one short live in both systems; compare
  transcript segment counts, chat peak minutes and topic spans.
- **Manual smoke test** of each screen as it lands (the current UI has no automated
  coverage either — see `docs/DEVELOPMENT.md` §2.9).

**End to end, before decommissioning:**

1. `rake primocut:import_legacy` against a copy of the real SQLite database.
2. Register a competitor channel → backfill runs → dashboards populate.
3. Let a recurring snapshot cycle fire → events appear in the Radar.
4. Submit a real live → pipeline completes → transcript + chat peaks + topics.
5. Build a cut → render → export → download the bundle; open it in CapCut.
6. `rake primocut:doctor` passes on a clean environment.

---

## 7. Open items

- **Realtime**: designated future experiment — compare Turbo Frames polling vs.
  Turbo Streams broadcasting on the same partials (§2.7).
- **Production**: currently local (GPU workstation). A future deployment needs a
  decision on where the GPU sidecar runs — same host, or split with the sidecar
  behind a queue on a GPU box.
- **Authentication**: not present today (single user). Rails 8 ships a generator
  when multi-user becomes real.

---

*Companion document: `docs/COMPONENTES.md` maps the current Python system this plan
migrates from.*
