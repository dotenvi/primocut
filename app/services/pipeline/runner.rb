module Pipeline
  # The single stage core, reused by the job and (later) the CLI — the one place
  # the stage order lives (docs §2.3, invariant 1). Flow: metadata → audio →
  # transcription → chat. Analysis (topics) is opt-in and lands with the Cut Room
  # phase, where the golden-rule SpanResolver already lives.
  #
  # Persistence is always ActiveRecord and doubles as the pay-once cache: a stage
  # whose artifact row already exists is skipped, so re-running is idempotent.
  # Only the reporter is injected (DbReporter for the job, LogReporter for the
  # CLI). Every external call is an injected adapter with a real default, so the
  # whole run is testable with fakes and no network or GPU. Ported from the PoC
  # `pipeline.py::run_stages`.
  class Runner
    Result = Data.define(:source_video, :transcript, :chat_signal, :warnings)

    def initialize(
      ytdlp: Adapters::Ytdlp.new,
      engine: Adapters::TranscriptionEngine.new,
      chat_downloader: Adapters::ChatDownloader.new,
      chat_threshold: (ENV["CHAT_ZSCORE_THRESHOLD"] || 2.0).to_f
    )
      @ytdlp = ytdlp
      @engine = engine
      @chat_downloader = chat_downloader
      @chat_threshold = chat_threshold
    end

    def call(source_video, reporter:, audio_dir:)
      warnings = []

      reporter.update(stage: "Metadata", progress: 5)
      refresh_metadata(source_video, warnings)

      # Audio + transcription: essential and store-backed. A cached transcript
      # skips the download and the GPU entirely.
      transcript = load_transcript(source_video)
      if transcript.nil?
        transcript = transcribe(source_video, reporter, audio_dir, warnings)
      else
        Rails.logger.info("Reusing cached transcript.")
      end

      # Degraded metadata (duration 0) is filled from the transcript's length.
      if source_video.duration_s <= 0 && transcript.duration.positive?
        source_video.update!(duration_s: transcript.duration.round)
      end

      reporter.update(stage: "Chat", progress: 65)
      chat_signal = load_chat_signal(source_video) || collect_chat(source_video)

      reporter.update(stage: "Done", progress: 100, video_status: :done)
      Result.new(source_video: source_video, transcript: transcript, chat_signal: chat_signal, warnings: warnings)
    end

    private

    # Degradable: a metadata failure keeps the row's existing data (it was set at
    # submit time) and records a warning instead of aborting.
    def refresh_metadata(source_video, warnings)
      meta = @ytdlp.fetch_metadata(source_video.url)
      source_video.update!(title: meta.title, channel: meta.channel, duration_s: meta.duration_s)
    rescue StandardError => e
      msg = "Metadata unavailable (#{e.class}: #{e.message}); keeping the submitted data."
      Rails.logger.warn(msg)
      warnings << msg
    end

    # Essential: any failure here is terminal for the run → Pipeline::Error.
    def transcribe(source_video, reporter, audio_dir, warnings)
      value = begin
        reporter.update(stage: "Audio download", progress: 15, video_status: :downloading)
        audio_path = @ytdlp.download_audio(source_video.url, audio_dir, video_id: source_video.youtube_id)
        reporter.update(stage: "Transcription", progress: 30, video_status: :transcribing)
        @engine.transcribe(audio_path, video_id: source_video.youtube_id)
      rescue StandardError => e
        raise Pipeline::Error, e.message
      end

      warnings.concat(@engine.degradation_warnings)
      persist_transcript(source_video, value)
      value
    end

    # Optional: no usable chat replay is a normal outcome (nil), never a failure.
    def collect_chat(source_video)
      messages = @chat_downloader.download(source_video.url)
      return nil if messages.nil?

      signal = ChatSignals.compute(messages, threshold: @chat_threshold)
      persist_chat_signal(source_video, signal)
      signal
    end

    # -- pay-once cache mapping (value object <-> jsonb row) --

    def load_transcript(source_video)
      row = source_video.transcript
      return nil unless row

      Transcript.new(
        youtube_id: source_video.youtube_id, language: row.language, model: row.model,
        segments: row.segments.map { |s| Segment.new(index: s["index"], start: s["start"], end: s["end"], text: s["text"]) }
      )
    end

    def persist_transcript(source_video, value)
      source_video.create_transcript!(
        language: value.language,
        model: value.model,
        segments: value.segments.map { |s| { "index" => s.index, "start" => s.start, "end" => s.end, "text" => s.text } }
      )
    end

    def load_chat_signal(source_video)
      row = source_video.chat_signal
      return nil unless row

      buckets = row.per_minute.map { |b| ChatSignals::Bucket.new(minute: b["minute"], msgs: b["msgs"], laughs: b["laughs"], emotes: b["emotes"]) }
      peaks = row.peaks.map { |p| ChatSignals::Peak.new(ts: p["ts"], intensity: p["intensity"], z: p["z"]) }
      ChatSignals::Signal.new(per_minute: buckets, peaks: peaks)
    end

    def persist_chat_signal(source_video, signal)
      source_video.create_chat_signal!(
        per_minute: signal.per_minute.map { |b| { "minute" => b.minute, "msgs" => b.msgs, "laughs" => b.laughs, "emotes" => b.emotes } },
        peaks: signal.peaks.map { |p| { "ts" => p.ts, "intensity" => p.intensity, "z" => p.z } }
      )
    end
  end
end
