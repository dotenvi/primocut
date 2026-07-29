module Cuts
  # Run one opt-in AI packaging action for a cut. Each costs money, so each is an
  # explicit choice — never a schedule, and never a bundle that runs the lot.
  class StartPackaging
    class UnknownKind < ArgumentError; end

    KINDS = %w[title thumb_brief frames rank audience].freeze

    # What a person is told when the kind is not one of those. An unknown kind can
    # only come from a tampered request, so the exception's own message — which
    # names the internals — belongs in the log, and this belongs on the page.
    UNKNOWN_ALERT = "Unknown packaging action.".freeze

    def call(cut:, kind:)
      case kind
      when "title", "thumb_brief" then CutPackagingJob.perform_later(cut.id, kind:)
      when "frames" then ExtractCutFramesJob.perform_later(cut.id)
      when "rank" then RankCutFramesJob.perform_later(cut.id)
      when "audience" then MatchAudienceJob.perform_later(cut.source_video_id)
      else raise UnknownKind, "unknown packaging action: #{kind.inspect} (use #{KINDS.inspect})"
      end
    end
  end
end
