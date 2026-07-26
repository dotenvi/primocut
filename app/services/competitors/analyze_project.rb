module Competitors
  # Run the opt-in AI analysis over a project's videos. Costs money, so it runs
  # only from an explicit user action — never from the snapshot cycle.
  #
  # Only the cache misses are dispatched: an unchanged content hash never
  # recharges. Selection is a pure read; the spending goes to the queue, so the
  # request returns immediately with the same counts the button promised.
  class AnalyzeProject
    def initialize(planner: nil)
      @planner = planner
    end

    def call(project:, kind:)
      plan = (@planner || AnalysisPlan).new(project, kind: kind).call
      VideoAnalysisJob.perform_later(plan.pending, kind) if plan.any?
      plan
    end
  end
end
