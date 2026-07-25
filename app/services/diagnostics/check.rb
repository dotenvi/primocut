module Diagnostics
  # One environment check's outcome. `warn` is a soft result: reported distinctly
  # but it does NOT fail the run (exit 0) — used for optional capabilities (e.g.
  # NVENC, whose absence only means the slower libx264 fallback). Ported from the
  # PoC `doctor.py::CheckResult`.
  Check = Data.define(:name, :ok, :detail, :fix, :warn) do
    def status = warn ? :warn : (ok ? :ok : :failed)
    def passed? = ok && !warn
    def failed? = !ok && !warn
  end
end
