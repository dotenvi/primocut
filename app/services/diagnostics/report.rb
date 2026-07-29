require "open3"
require "timeout"

module Diagnostics
  # Environment diagnostics for `rake primocut:doctor`. Validates what the app
  # needs to run end to end — GPU/CUDA (WSL2), FFmpeg (+ the optional NVENC
  # encoder), yt-dlp (both the binary AND YouTube actually answering it), the
  # Python transcription sidecar, the LLM key, the YouTube Data API key, and the
  # database — and returns a list of [[Diagnostics::Check]].
  # It installs nothing; it only reports, each failure carrying its fix command.
  #
  # Ported from the PoC `doctor.py`, minus Redis (Solid Queue replaced it) and the
  # WhisperX align venv (folded into the sidecar's own `doctor`). Every collaborator
  # is injected with a real default, so the whole report runs in tests with no GPU
  # and no network. Presentation (the table, the exit code) lives in the rake task.
  class Report
    def initialize(
      run: method(:default_run),
      engine: -> { Adapters::TranscriptionEngine.new },
      youtube: -> { Adapters::YoutubeApi.from_env },
      env: ENV,
      db: method(:default_db),
      readable: ->(path) { File.readable?(path) }
    )
      @run = run
      @engine = engine
      @youtube = youtube
      @env = env
      @db = db
      @readable = readable
    end

    def call
      [
        check_gpu,
        check_ffmpeg,
        check_nvenc,
        check_ytdlp,
        check_ytdlp_extraction,
        check_sidecar,
        check_llm_key,
        check_youtube,
        check_db
      ]
    end

    private

    # NVIDIA GPU visible via `nvidia-smi` (driver on Windows, exposed to WSL2).
    def check_gpu
      name = "GPU / CUDA (WSL2)"
      res = @run.call([ "nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader" ], timeout: 15)
      return fail(name, "nvidia-smi not found",
                  fix: "Install the NVIDIA driver on Windows and enable WSL2 GPU; confirm with `nvidia-smi`.") if res.missing?
      return fail(name, detail_of(res, "returncode != 0"), fix: "Check the NVIDIA driver and WSL2 GPU support.") unless res.ok?

      pass(name, res.out.strip.lines.first&.strip.presence || "ok")
    end

    def check_ffmpeg
      name = "FFmpeg"
      res = @run.call([ "ffmpeg", "-hide_banner", "-version" ], timeout: 15)
      return fail(name, "not found on PATH", fix: "sudo apt install ffmpeg") if res.missing?
      return fail(name, detail_of(res, "ffmpeg failed"), fix: "sudo apt install ffmpeg") unless res.ok?

      pass(name, res.out.strip.lines.first&.strip.presence || "ok")
    end

    # NVENC (h264_nvenc) actually encodes — the default clip-render encoder. A soft
    # WARN, never a hard failure: rendering falls back to libx264 (slower) if it is
    # unavailable, so its absence does not break the environment.
    def check_nvenc
      name = "NVENC (h264_nvenc)"
      # A real (if tiny) encode: 256x144 for 10 frames. NVENC rejects the sub-minimum
      # frame the PoC probed with (128x72 @ 0.1s → "-22 Invalid argument") even where
      # it works, so that input produced a false negative on ffmpeg 7.x.
      res = @run.call(
        [ "ffmpeg", "-hide_banner", "-loglevel", "error",
          "-f", "lavfi", "-i", "color=c=black:s=256x144:d=1:r=10",
          "-c:v", "h264_nvenc", "-f", "null", "-" ], timeout: 30
      )
      return warn(name, "FFmpeg not found", fix: "sudo apt install ffmpeg") if res.missing?
      return pass(name, "h264_nvenc encodes") if res.ok?

      warn(name, res.err.to_s.strip.lines.last&.strip.to_s[0, 200].to_s.presence || "h264_nvenc failed",
           fix: "Rendering falls back to libx264 (slower). For NVENC, confirm the NVIDIA driver on " \
                "Windows exposes the encoder to WSL2, or set RENDER_ENCODER=libx264.")
    end

    # yt-dlp is shelled out (never imported), so the binary on PATH is what matters.
    def check_ytdlp
      name = "yt-dlp"
      cmd = Adapters::Ytdlp.default_base_cmd + [ "--version" ]
      res = @run.call(cmd, timeout: 15)
      return fail(name, "not found on PATH", fix: "pipx install yt-dlp (or set YTDLP_CMD).") if res.missing?
      return fail(name, detail_of(res, "yt-dlp failed"), fix: "Reinstall yt-dlp; check YTDLP_CMD.") unless res.ok?

      pass(name, "yt-dlp #{res.out.strip.lines.first&.strip}")
    end

    # A version number proves the binary runs, not that YouTube will answer it —
    # and "Sign in to confirm you're not a bot" is thrown per IP, so the binary
    # check passes green while every real download dies. This asks YouTube for one
    # video's metadata (`-J`, no media) so the bot-check surfaces HERE instead of
    # mid-render, where it costs a stuck cut.
    def check_ytdlp_extraction
      name = "yt-dlp extraction"
      cookies = Adapters::Ytdlp.default_cookie_args(@env)
      unreadable = unreadable_cookie_jar(cookies)
      # Checked BEFORE probing, because yt-dlp does not complain about a cookie file
      # it cannot read — it drops to anonymous and comes back with the bot-check. The
      # probe would then blame the IP and tell you to configure the cookies you
      # already configured.
      if unreadable
        return fail(name, "the configured cookie jar cannot be read: #{unreadable}",
                    fix: "Fix YTDLP_COOKIES — yt-dlp ignores an unreadable jar silently and " \
                         "falls back to an anonymous request.")
      end

      # Probed with the SAME flags the pipeline downloads with — a probe that passes
      # under a different configuration than the real thing measures nothing.
      js = Adapters::Ytdlp.default_js_runtime_args(@env)
      cmd = Adapters::Ytdlp.default_base_cmd + [ "-J", "--no-warnings", *cookies, *js, probe_url ]
      res = @run.call(cmd, timeout: 120)
      return fail(name, "yt-dlp is not on PATH", fix: "pipx install yt-dlp (or set YTDLP_CMD).") if res.missing?
      return pass(name, "extraction ok#{cookie_note(cookies)}#{js_note(js)}") if res.ok?

      detail = detail_of(res, "yt-dlp could not extract the probe video")
      fail(name, detail, fix: extraction_fix(detail, cookies))
    end

    # The video the probe asks about: "Me at the zoo", the first video uploaded to
    # YouTube (2005). Chosen for the one property that matters here — it is the
    # least likely video on the platform to ever be taken down. Overridable all the
    # same, since the check is about the extractor, not about this video.
    def probe_url
      @env["DOCTOR_PROBE_URL"].presence || "https://www.youtube.com/watch?v=jNQXAC9IVRw"
    end

    def cookie_note(cookies) = cookies.empty? ? " (anonymous)" : " (cookies: #{cookies.first.delete_prefix('--')})"

    def js_note(js) = js.empty? ? "" : " (js: #{js.last})"

    # The jar path, when one is configured and unreadable; nil otherwise. A browser
    # profile (--cookies-from-browser) is yt-dlp's to locate, not ours.
    def unreadable_cookie_jar(cookies)
      return nil unless cookies.first == "--cookies"

      path = cookies.last
      @readable.call(path) ? nil : path
    end

    # The bot-check has one real remedy and it is not "retry" — say so, instead of
    # sending the user to update yt-dlp for a block that is about the IP. And a dead
    # probe video says nothing about the environment, so it must not read as one.
    def extraction_fix(detail, cookies)
      # YouTube withholds the real formats until its JS challenge is solved, and then
      # reports the absence as a FORMAT problem. Taken at face value it sends you
      # hunting a format selector that is not broken.
      if detail.match?(/format is not available|No video formats|Only images|challenge/i)
        return "yt-dlp could not solve YouTube's JS challenge, so only storyboard images were offered. " \
               "Install a JS runtime and the solver script: `pipx inject yt-dlp yt-dlp-ejs`, then set " \
               "YTDLP_JS_RUNTIMES=node (yt-dlp enables only deno by default). Installing the solver beside " \
               "yt-dlp avoids --remote-components, which would fetch and run remote JS at download time."
      end

      if detail.match?(/unavailable|private|removed|does not exist|terminated/i)
        return "The probe video itself is gone, which says nothing about your setup — " \
               "point DOCTOR_PROBE_URL at any video that plays."
      end

      return "Update yt-dlp (`pipx upgrade yt-dlp`) — the YouTube extractor breaks often — " \
             "or try another client via YTDLP_PLAYER_CLIENTS." unless detail.match?(/not a bot|Sign in to confirm|confirm your age|cookies/i)

      base = "YouTube is challenging this IP, so no download will succeed until it is answered with a " \
             "logged-in session: export cookies (Netscape format) and set YTDLP_COOKIES=/path/to/cookies.txt, " \
             "or YTDLP_COOKIES_FROM_BROWSER=chrome when the browser runs on THIS machine."
      cookies.empty? ? base : "#{base} The cookies currently configured (#{cookies.first}) were rejected — export them again from a logged-in session."
    end

    # The Python transcription sidecar reports its own health (faster-whisper +
    # CUDA visibility) as JSON — it owns its CUDA environment (docs §5.2).
    def check_sidecar
      name = "Transcription sidecar"
      envelope = @engine.call.doctor
      if envelope["ok"]
        pass(name, "python #{envelope['python']}, faster-whisper #{envelope['faster_whisper']}, " \
                   "#{envelope['cuda_device_count']} CUDA device(s)")
      else
        detail = envelope["cuda_error"] || envelope["faster_whisper_error"] || "engine reported not ok"
        fail(name, detail, fix: "Check the sidecar venv (faster-whisper installed, CUDA libs loadable).")
      end
    rescue Adapters::TranscriptionEngine::TranscriptionError => e
      fail(name, e.message, fix: "Check the sidecar venv and `ENGINE_CMD` (python3 sidecar/transcription_engine.py doctor --json).")
    end

    def check_llm_key
      name = "LLM key (ANTHROPIC_API_KEY)"
      return pass(name, "present") if @env["ANTHROPIC_API_KEY"].to_s.strip.present?

      fail(name, "not set", fix: "Copy .env.example to .env and fill in ANTHROPIC_API_KEY.")
    end

    # YouTube Data API key validated with a cheap real call (1 quota unit).
    def check_youtube
      name = "YouTube Data API (YOUTUBE_API_KEY)"
      units = @youtube.call.probe
      pass(name, "valid (#{units} unit consumed)")
    rescue Adapters::YoutubeApi::Error => e
      fail(name, e.message,
           fix: "Set YOUTUBE_API_KEY (YouTube Data API v3; free tier: 10,000 units/day) and confirm the key/quota.")
    rescue StandardError => e
      fail(name, e.message, fix: "Check the key and that the YouTube Data API v3 is enabled with available quota.")
    end

    def check_db
      name = "Database (PostgreSQL)"
      pass(name, @db.call.to_s)
    rescue StandardError => e
      fail(name, e.message, fix: "Start Postgres (`docker compose up -d`) and run `bin/rails db:prepare`.")
    end

    # -- helpers --

    def pass(name, detail) = Check.new(name:, ok: true, detail:, fix: nil, warn: false)
    def fail(name, detail, fix: nil) = Check.new(name:, ok: false, detail:, fix:, warn: false)
    def warn(name, detail, fix: nil) = Check.new(name:, ok: true, detail:, fix:, warn: true)

    def detail_of(res, fallback)
      (res.err.to_s.strip.presence || res.out.to_s.strip.presence || fallback).lines.first.to_s.strip
    end

    # Real shell probe: captures stdout/stderr, maps a missing binary and a hang to
    # distinct results. Replaced wholesale by a fake in tests.
    def default_run(cmd, timeout: 15)
      out, err, status = Timeout.timeout(timeout) { Open3.capture3(*cmd, stdin_data: "") }
      RunResult.new(out:, err:, ok: status.success?, missing: false)
    rescue Errno::ENOENT
      RunResult.new(out: "", err: "", ok: false, missing: true)
    rescue Timeout::Error
      RunResult.new(out: "", err: "timed out after #{timeout}s", ok: false, missing: false)
    end

    def default_db
      ActiveRecord::Base.connection.execute("SELECT 1")
      ActiveRecord::Base.connection_db_config.database
    end
  end
end
