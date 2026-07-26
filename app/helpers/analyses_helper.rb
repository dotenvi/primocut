module AnalysesHelper
  LABELS = { "title" => "Analyze titles", "thumbnail" => "Analyze thumbnails" }.freeze

  # The button says what the click will cost before it is clicked: how many videos
  # would be paid for, or that everything is already cached and it would be free.
  def analysis_label(plan)
    base = LABELS.fetch(plan.kind, "Analyze")
    return base if plan.total.zero?
    return "#{base} · all cached" unless plan.any?

    "#{base} · #{plan.pending_count} new"
  end

  def analysis_notice(plan)
    return "No settled video to analyze yet — collection needs to mature first." if plan.total.zero?
    return "All #{plan.total} videos are already analyzed — nothing to pay for." unless plan.any?

    "Analyzing #{pluralize(plan.pending_count, 'video')} (#{plan.cached} already cached). " \
      "Open a video to follow it."
  end
end
