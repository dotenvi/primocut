module Pipeline
  # The single source of stage truth, shared by everything that draws the
  # pipeline. Ports the PoC `lib/steps.js` so the rail, the log and the report
  # can never disagree about what a stage did.
  #
  # A step is only `done` when its artifact is actually there — never merely
  # because the run finished. A step that produced nothing resolves to one of two
  # honest states, told apart by whether the run entered it at all:
  # `empty` (it ran and had nothing to produce, e.g. chat with no replay) or
  # `skipped` (it was never entered, e.g. topics nobody asked for).
  class Steps
    Step = Data.define(:key, :label, :match, :evidence_deferred)

    STEPS = [
      Step.new(key: "metadata", label: "Metadata", match: "metadata", evidence_deferred: false),
      # Audio's artifact is ephemeral — the file is discarded — so its completion
      # is only ever evidenced later, by the transcript. Without this flag the
      # absence of its own artifact would read as "produced nothing".
      Step.new(key: "audio", label: "Audio download", match: "audio", evidence_deferred: true),
      Step.new(key: "transcription", label: "Transcription", match: "transcription", evidence_deferred: false),
      Step.new(key: "chat", label: "Chat", match: "chat", evidence_deferred: false),
      Step.new(key: "topics", label: "Topics", match: "topics", evidence_deferred: false)
    ].freeze

    Row = Data.define(:key, :label, :state, :duration_s)

    def initialize(source_video, now: Time.current)
      @video = source_video
      @job = source_video.pipeline_jobs.order(:created_at, :id).last
      @now = now
    end

    def call
      durations = step_durations
      STEPS.each_with_index.map do |step, index|
        Row.new(key: step.key, label: step.label, state: state_for(step, index), duration_s: durations[step.key])
      end
    end

    # What the pipeline is doing overall, for the one-word summary beside the rail.
    def overall
      return "failed" if %w[error stopped].include?(@video.status)
      return "done" if @video.status == "done"

      "running"
    end

    def warnings = Array(@job&.warnings)

    private

    def active? = @video.active?

    # The index of the step the current stage names, or -1 while queued or on a
    # terminal marker ("Done") that bounds a step without being one.
    def current_index
      @current_index ||= begin
        stage = @job&.stage.to_s.downcase
        STEPS.index { |step| stage.include?(step.match) } || -1
      end
    end

    # Positive confirmation that a step's artifact exists.
    def completed
      @completed ||= begin
        transcript = @video.transcript
        segments = transcript && Array(transcript.segments).any?
        {
          "metadata" => @video.title.present?,
          "audio" => segments,
          "transcription" => segments,
          "chat" => @video.chat_signal.present?,
          "topics" => @video.topics.any?
        }
      end
    end

    # A step with no artifact is settled either way — it just matters whether the
    # run ever entered it.
    def settled(step) = entered.include?(step.key) ? "empty" : "skipped"

    def entered
      @entered ||= history.filter_map { |entry| step_key(entry[:stage]) }.to_set
    end

    def state_for(step, index)
      return "done" if completed[step.key]
      return "running" if active? && index == current_index
      # Passed in the current run: a step that persists its artifact the moment it
      # runs and shows none produced nothing. Only a deferred-evidence step may
      # still legitimately be waiting for its proof.
      return step.evidence_deferred ? "done" : settled(step) if active? && current_index >= 0 && index < current_index
      return "failed" if %w[error stopped].include?(@video.status) && index == current_index
      return "pending" if active?

      settled(step)
    end

    def step_key(label)
      text = label.to_s.downcase
      STEPS.find { |step| text.include?(step.match) }&.key
    end

    # `stage_history` carries two shapes: runs recorded here store
    # `{stage:, at:}`, while rows imported from the PoC before that stored the
    # bare stage name. The older shape simply yields no duration.
    def history
      @history ||= Array(@job&.stage_history).map do |entry|
        entry.is_a?(Hash) ? { stage: entry["stage"], at: parse_time(entry["at"]) } : { stage: entry, at: nil }
      end
    end

    # A step's duration is the gap to the next transition; the one still running
    # measures up to now, so it ticks while the screen polls.
    def step_durations
      timed = history.select { |entry| entry[:at] }
      timed.each_with_index.each_with_object({}) do |(entry, index), out|
        key = step_key(entry[:stage])
        next if key.nil? # a terminal marker bounds a step without being one

        following = timed[index + 1]&.dig(:at) || @now
        out[key] = [ following - entry[:at], 0 ].max
      end
    end

    def parse_time(value) = value.present? ? Time.zone.parse(value.to_s) : nil
  end
end
