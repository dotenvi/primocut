require "json"
require "tempfile"

module Adapters
  # Drives the `primocut-engine` Python sidecar (docs §1.4). Ruby never imports
  # Python — it runs the process, reads the JSON status envelope from stdout, and
  # reads the transcript payload from the `--out` file (a long transcript is
  # megabytes of JSON; a pipe risks blocking, so it goes to a file). Ported from
  # the PoC `transcription/` behind the same `TranscriptionEngine` seam.
  class TranscriptionEngine
    # A transcription failed — essential-stage error the pipeline aborts on.
    class TranscriptionError < StandardError; end

    # A very long live can legitimately transcribe for tens of minutes (first-run
    # model download + a multi-hour audio). The default mirrors the PoC's generous
    # 6h RQ job timeout — the cap exists to reclaim a genuinely hung GPU process.
    DEFAULT_TIMEOUT_S = 6 * 3600

    attr_reader :degradation_warnings

    def initialize(
      engine_cmd: self.class.default_engine_cmd,
      model: ENV["WHISPER_MODEL"] || "large-v3-turbo",
      language: ENV["WHISPER_LANGUAGE"] || "pt",
      device: ENV["WHISPER_DEVICE"] || "cuda",
      compute_type: ENV["WHISPER_COMPUTE_TYPE"] || "float16",
      compute_fallbacks: ENV["WHISPER_COMPUTE_FALLBACKS"] || "float16,int8_float16,int8",
      timeout_s: (ENV["TRANSCRIBE_TIMEOUT_S"] || DEFAULT_TIMEOUT_S).to_i,
      runner: ProcessRunner.new
    )
      @engine_cmd = engine_cmd
      @model = model
      @language = language
      @device = device
      @compute_type = compute_type
      @compute_fallbacks = compute_fallbacks
      @timeout_s = timeout_s
      @runner = runner
      @degradation_warnings = []
    end

    def self.default_engine_cmd
      return ENV["ENGINE_CMD"].split if ENV["ENGINE_CMD"].present?

      [ "python3", Rails.root.join("sidecar", "primocut_engine.py").to_s ]
    end

    # Engine/model identifier — goes into Transcript.model and the report.
    def name
      "faster-whisper:#{@model}"
    end

    def transcribe(audio_path, video_id:, language: nil)
      lang = language || @language
      Tempfile.create([ "transcript-#{video_id}", ".json" ]) do |out|
        cmd = [
          *@engine_cmd, "transcribe",
          "--audio", audio_path.to_s,
          "--language", lang,
          "--model", @model,
          "--device", @device,
          "--compute-type", @compute_type,
          "--compute-fallbacks", @compute_fallbacks,
          "--out", out.path
        ]
        envelope = run_engine(cmd)
        @degradation_warnings = Array(envelope["degradation_warnings"])
        build_transcript(video_id, out.path)
      end
    end

    # Engine self-check (used by the doctor rake task in a later phase).
    def doctor
      run_engine([ *@engine_cmd, "doctor", "--json" ])
    end

    private

    # Run the sidecar and return the parsed stdout envelope, mapping every failure
    # mode (timeout, non-zero exit, unreadable output) to TranscriptionError.
    def run_engine(cmd)
      result = begin
        @runner.call(cmd, timeout: @timeout_s)
      rescue ProcessRunner::TimeoutError => e
        raise TranscriptionError, e.message
      end

      envelope = parse_envelope(result.stdout)
      unless result.status.success?
        message = envelope["error"] || result.stderr.to_s.strip[-300, 300] || "unknown error"
        raise TranscriptionError, "sidecar failed: #{message}"
      end
      envelope
    end

    def parse_envelope(stdout)
      text = stdout.to_s.strip
      return {} if text.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      {} # a crash before the envelope was printed → treated as an error by the caller
    end

    def build_transcript(video_id, out_path)
      data = JSON.parse(File.read(out_path))
      segments = Array(data["segments"]).map do |s|
        Pipeline::Segment.new(
          index: s["index"], start: s["start"].to_f, end: s["end"].to_f, text: s["text"].to_s
        )
      end
      Pipeline::Transcript.new(
        youtube_id: video_id,
        language: data["language"] || @language,
        model: data["model"] || name,
        segments: segments
      )
    rescue Errno::ENOENT, JSON::ParserError => e
      raise TranscriptionError, "sidecar produced no readable transcript: #{e.message}"
    end
  end
end
