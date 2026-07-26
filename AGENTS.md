# AGENTS.md

Canonical agent instructions for PRIMOCUT (Rails). Every line here is loaded into
context each request — keep it dense and current. On any contradiction with the
code, the **code wins**; then fix the docs.

> **Status: the migration is complete** (released at `0.5.0`). This repository is
> the Rails rewrite of the Python PoC that lives in `../primocut-poc` (GitHub:
> `dotenvi/primocut-poc`); the PoC is kept as the executable specification, not as
> something to delete. Work now is refinement of the ported screens, so every
> section below describes code that exists — read it, do not assume it.

## What this is

PRIMOCUT turns a **YouTube live URL** into a **navigable report**: full transcript
(clickable timestamps), per-minute chat activity (z-score peaks as clip candidates),
and opt-in LLM macro topics. Everything derives from **real** timestamps, so every
`&t=SECONDS` link lands exactly on the moment. Two further capabilities grew on top:
competitor-channel modeling and assisted cutting/packaging of clips.

- Migration plan and rationale: `docs/RAILS_MIGRATION.md` (canonical; the PT
  translation `docs/MIGRACAO_RAILS.md` is study material and may lag).
- Map of the PoC being migrated from: `docs/COMPONENTES.md`.
- The PoC itself is the executable specification — read it before porting a domain.

## The two invariants (they shape everything)

1. **One pipeline core.** Stage order (metadata → audio → transcription → chat →
   analysis) lives in exactly **one** place. In the PoC that is
   `pipeline.py::run_stages`; here it is `Pipeline::Runner`,
   called by both the job and the CLI, differing only by an injected reporter.
   **Never duplicate stage logic.**

2. **The golden rule of analysis.** The LLM returns segment **indices**, **never**
   timestamps. Index→time resolution clamps to real segments (`resolve_span` in the
   PoC → `Cuts::SpanResolver`), and that clamp is the **final
   authority** — not the provider's schema. Forced tool use is the first line of
   defense (verified working, `docs/RAILS_MIGRATION.md` §5.1), the clamp is the one
   that cannot fail. No prompt or parser may trust model-emitted times.

## Stack

Rails 8 · Hotwire · Tailwind CSS · PostgreSQL (Docker) · Solid Queue · RubyLLM ·
a thin **Python sidecar** (~584 LOC) retained only for transcription
(faster-whisper + WhisperX alignment). No Redis: Solid Queue replaces the queue
**and** the scheduler, and a `gpu` queue with `threads: 1` replaces the GPU lock.

- Postgres runs via `docker compose up -d` (see `docker-compose.yml`).
- `yt-dlp`, `chat_downloader` and FFmpeg are **shelled out to**, never wrapped in
  Python glue — the PoC already invokes them as subprocesses.
- The sidecar owns its own CUDA environment (`_preload_cuda_libs`); Rails must never
  need CUDA env vars. See `docs/RAILS_MIGRATION.md` §5.2.

## Architecture

```
app/
  models/       ActiveRecord: persistence, associations, scopes, validations.
  services/     Domain operations, grouped BY DOMAIN. The real logic lives here.
  jobs/         ActiveJob: thin. Parse args → call a service → report progress.
  adapters/     One class per external dependency. Swappable, fakeable in tests.
  controllers/  Thin: params → service → render.
  views/        ERB + Hotwire. Everything is a partial.
```

Service namespaces mirror the PoC's domains — `Pipeline::`, `Competitors::`,
`Metrics::`, `Cuts::` — plus one per screen for read-side composition:
`Radar::`, `Activity::`, `Niche::`, `Navigation::`, and `Events::` for what they
share. A screen object is what keeps a controller at `params → service → render`
when the screen needs more than one read.

The opt-in AI pass over a competitor's video is **analysis**
(`Competitors::VideoAnalysis`), never "enrichment" — that word names only the
`video_enrichments` table it writes to, and the pass runs on competitor videos
alone, which is why it lives under `Competitors::`.

## Design conventions

- **SOLID, weighted:** SRP and DIP high; OCP low (no speculative extension points);
  LSP/ISP where adapters and reporters demand it. The PoC already practices
  dependency inversion at 51 injection points — **carry that over, do not lose it**.
- **Services** expose one public method (`call`); dependencies arrive via the
  constructor with real defaults, so tests inject fakes.
- **No Repository pattern over ActiveRecord** — AR *is* the persistence abstraction.
  Database portability comes from keeping computation in Ruby (POROs), not from a
  wrapper layer. Push a query into SQL only when measured slow, and isolate it in a
  query object so the coupling is visible.
- **Errors:** domain exceptions in a small hierarchy — one model, caught at the
  level the context demands. Request path → `rescue_from` → 404/422. Batch jobs →
  rescue per item, persist `state: :error`, continue. No Result objects by default.
- **DRY under KISS.** Duplication is cheaper than the wrong abstraction. Abstract on
  the third repetition *that shares a reason to change*.
- **Comments explain *why*, never *what*.** The PoC's rationale comments encode
  failures already paid for — when porting, read them first and preserve them.
  Delete narration, keep reasoning.

## Conventions

- **Language**: everything committed is **English** — code, comments, user-visible
  strings, and all `.md` docs. The one authorized exception is
  `docs/MIGRACAO_RAILS.md` (a PT translation, explicitly sanctioned; the English
  file is canonical). Talk to the user in **Portuguese** (chat only). A task asking
  for new Portuguese docs is a mistake — confirm, don't write PT into an artifact.
- **Tests**: run them yourself after changes that need validation — don't ask. The
  suite must need **no GPU and no network** (fakes + injected adapters), exactly like
  the PoC's 487-test suite. Work TDD: write the failing test first.
- **Commits**: commit **directly to `main`** — no branch/PR unless explicitly asked.
  Conventional Commits, English, with a `Co-authored-by` trailer. **Never commit
  without being asked.** When asked for a commit *list*: chronological build order,
  tests-first, and output both the full `git add …` and `git commit -m "…"` commands.
- **Versioning**: SemVer 2.0.0, currently **0.x** on purpose (public API = HTTP
  routes, CLI, env vars — treated as unstable). `feat`→minor, `fix`→patch, breaking
  →minor while in 0.x. Keep a Changelog format in `CHANGELOG.md`. The version lives
  in **`VERSION` at the repo root** as the single source of truth. **Never bump the
  version or stamp a release without an explicit request** — the user accumulates
  commits and decides the number.

## Gotchas

- No CPU fallback for transcription (by decision, inherited from the PoC).
- Audio is ephemeral (temp dir, discarded per run/job) — nothing to clean up.
- RubyLLM ships a **stale model registry**: new models raise `ModelNotFoundError`
  until `RubyLLM.models.refresh!` runs. Also, `temperature` is rejected by
  `claude-sonnet-5` — do not send it.
- Moving this directory breaks the sidecar venv (absolute paths in console-script
  shebangs and the editable `.pth`) — the PoC rename already hit this.
