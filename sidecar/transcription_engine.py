#!/usr/bin/env python3
"""transcription-engine — the thin transcription sidecar (docs §1.4).

The one Python process the Rails app keeps: GPU transcription is genuinely
Python-bound (faster-whisper / CTranslate2 / CUDA). Everything else moved to
Ruby. The name mirrors its only caller, [[Adapters::TranscriptionEngine]] — the
two sides of one seam.

Contract:
    transcription-engine transcribe --audio PATH --language pt --model large-v3-turbo \
        --device cuda --compute-type float16 --compute-fallbacks float16,int8 \
        --out OUT.json
    transcription-engine doctor --json

Rules (all validated by the boundary spike, docs §5.2):
- stdout carries JSON ONLY — a small status envelope. All logging goes to stderr.
- The transcript PAYLOAD goes to `--out FILE`, never stdout: a multi-hour
  transcript is megabytes of JSON and a pipe risks blocking the reader.
- A non-zero exit means failure, with a JSON error body on stdout.
- The caller runs this in its own process group and kills it by timeout.

(The `align` subcommand from the contract belongs to the Cut Room's boundary
refinement and lands with that phase; only transcription is wired here.)
"""

from __future__ import annotations

import argparse
import json
import sys
import time


def log(message: str) -> None:
    """Diagnostics go to stderr so stdout stays pure JSON."""
    print(message, file=sys.stderr, flush=True)


def _preload_cuda_libs() -> None:
    """Preload cuBLAS/cuDNN from the NVIDIA pip packages.

    Under WSL2 the driver lives on Windows, but the CUDA runtime libs arrive via
    pip (`nvidia-cublas-cu12`, `nvidia-cudnn-cu12`) and are NOT on
    LD_LIBRARY_PATH. Loading them RTLD_GLOBAL here makes the symbols available for
    ctranslate2 to resolve `libcublas.so.12` etc. by soname. Without this the
    sidecar cannot use the GPU at all, even though the libs are installed — the
    single hardest-won lesson of the boundary spike (docs §5.2). Do not remove.
    """
    import ctypes
    import glob
    import os

    try:
        import nvidia  # the nvidia-*-cu12 packages install under the `nvidia` namespace
    except ImportError:
        return  # without the pip packages: let ctranslate2 try the system PATH

    # `nvidia` is a namespace package (PEP 420): no __file__, use __path__.
    bases = list(getattr(nvidia, "__path__", []) or [])
    patterns = [
        "cublas/lib/libcublasLt.so*",  # cublas dependency — load first
        "cublas/lib/libcublas.so*",
        "cudnn/lib/libcudnn*.so*",
    ]
    sos: list[str] = []
    for base in bases:
        for pat in patterns:
            sos.extend(sorted(glob.glob(os.path.join(base, pat))))

    # Several passes: resolves dependencies between the libs regardless of order.
    pending = list(sos)
    for _ in range(3):
        if not pending:
            break
        still: list[str] = []
        for so in pending:
            try:
                ctypes.CDLL(so, mode=ctypes.RTLD_GLOBAL)
            except OSError:
                still.append(so)
        pending = still


def _candidate_compute_types(device: str, compute_type: str, fallbacks: str) -> list[str]:
    """Primary compute_type followed by the fallbacks (only meaningful on GPU)."""
    if device != "cuda":
        return [compute_type]
    ordered = [compute_type] + [c.strip() for c in fallbacks.split(",") if c.strip()]
    out: list[str] = []
    for c in ordered:  # de-dup, preserve order
        if c not in out:
            out.append(c)
    return out


def _load_model(model: str, device: str, compute_type: str, fallbacks: str, warnings: list[str]):
    """Load faster-whisper, degrading the compute_type down the ladder on GPU
    failures (OOM/runtime). Records a warning whenever it falls back."""
    from faster_whisper import WhisperModel  # lazy: heavy/GPU import

    candidates = _candidate_compute_types(device, compute_type, fallbacks)
    errors: list[tuple[str, Exception]] = []
    for idx, ct in enumerate(candidates):
        log(f"Loading {model} on {device} ({ct})…")
        try:
            built = WhisperModel(model, device=device, compute_type=ct)
        except Exception as exc:  # OOM/CUDA/runtime → try the next compute_type
            log(f"compute_type '{ct}' failed: {exc}")
            errors.append((ct, exc))
            continue
        if idx > 0:
            msg = (
                f"Transcription degraded the compute_type to '{ct}' "
                f"(the preferred '{candidates[0]}' failed on the GPU)."
            )
            log(msg)
            warnings.append(msg)
        return built

    tried = ", ".join(ct for ct, _ in errors)
    last = errors[-1][1] if errors else "unknown"
    raise RuntimeError(
        f"Transcription failed on every compute_type ({tried}). Use a smaller "
        f"model, free VRAM, or adjust the compute type. Last error: {last}"
    )


def cmd_transcribe(args: argparse.Namespace) -> int:
    warnings: list[str] = []
    if args.device == "cuda":
        _preload_cuda_libs()

    model = _load_model(args.model, args.device, args.compute_type, args.compute_fallbacks, warnings)

    raw_segments, info = model.transcribe(args.audio, language=args.language, vad_filter=True)
    total = float(getattr(info, "duration", 0.0) or 0.0)

    segments: list[dict] = []
    last_logged = 0.0
    for i, s in enumerate(raw_segments):
        segments.append(
            {"index": i, "start": float(s.start), "end": float(s.end), "text": (s.text or "").strip()}
        )
        # faster-whisper emits nothing on its own; without progress logs a long
        # run looks frozen for minutes.
        if total and (s.end - last_logged) >= 30.0:
            last_logged = s.end
            pct = int(min(100.0, s.end / total * 100))
            log(f"Transcription: {s.end:.0f}s / {total:.0f}s ({pct}%, {i + 1} segments)")

    detected = getattr(info, "language", args.language) or args.language
    model_name = f"faster-whisper:{args.model}"
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"language": detected, "model": model_name, "segments": segments}, fh, ensure_ascii=False)

    envelope = {
        "ok": True,
        "segments": len(segments),
        "language": detected,
        "model": model_name,
        "degradation_warnings": warnings,
    }
    json.dump(envelope, sys.stdout)
    return 0


def cmd_doctor(_args: argparse.Namespace) -> int:
    """Report the engine's own health as JSON (a subset of the full doctor)."""
    report: dict = {"python": sys.version.split()[0]}

    try:
        import faster_whisper  # noqa: F401

        report["faster_whisper"] = getattr(faster_whisper, "__version__", "unknown")
    except Exception as exc:  # noqa: BLE001
        report["faster_whisper"] = None
        report["faster_whisper_error"] = str(exc)

    _preload_cuda_libs()
    try:
        import ctranslate2

        report["cuda_device_count"] = ctranslate2.get_cuda_device_count()
    except Exception as exc:  # noqa: BLE001
        report["cuda_device_count"] = 0
        report["cuda_error"] = str(exc)

    report["ok"] = bool(report.get("faster_whisper")) and report.get("cuda_device_count", 0) > 0
    json.dump(report, sys.stdout)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="transcription-engine")
    sub = parser.add_subparsers(dest="command", required=True)

    t = sub.add_parser("transcribe")
    t.add_argument("--audio", required=True)
    t.add_argument("--language", default="pt")
    t.add_argument("--model", default="large-v3-turbo")
    t.add_argument("--device", default="cuda")
    t.add_argument("--compute-type", dest="compute_type", default="float16")
    t.add_argument("--compute-fallbacks", dest="compute_fallbacks", default="float16,int8_float16,int8")
    t.add_argument("--out", required=True)
    t.set_defaults(func=cmd_transcribe)

    d = sub.add_parser("doctor")
    d.add_argument("--json", action="store_true")
    d.set_defaults(func=cmd_doctor)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    started = time.time()
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001 — every failure is a JSON error body + non-zero exit
        json.dump({"error": f"{type(exc).__name__}: {exc}"}, sys.stdout)
        log(f"failed after {time.time() - started:.2f}s: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
