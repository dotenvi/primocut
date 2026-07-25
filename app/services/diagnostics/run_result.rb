module Diagnostics
  # The outcome of a shelled-out probe command. `missing` distinguishes "the
  # binary is not on PATH" (a different fix) from "it ran and failed". Kept tiny
  # and injectable so the checks are testable without touching real binaries.
  RunResult = Data.define(:out, :err, :ok, :missing) do
    def ok? = ok
    def missing? = missing
  end
end
