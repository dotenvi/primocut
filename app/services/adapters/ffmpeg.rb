require "pathname"

module Adapters
  # FFmpeg wrapper for the clip render: the fine cut of a downloaded section into
  # the final MP4, plus deterministic candidate-frame extraction. Thin subprocess
  # wrappers behind the injectable `Shell` seam, so the tests fake FFmpeg entirely
  # — no re-encode, no GPU. Ported from the PoC `render/encode.py` + `render/frames.py`.
  #
  # RE-ENCODE is the default (NVENC `h264_nvenc`, falling back to `libx264`): it
  # produces frame-exact start/end boundaries a keyframe stream copy cannot. `copy`
  # is opt-in and documented as keyframe-imprecise. Output is MP4 (H.264 + AAC) at
  # the original resolution.
  class Ffmpeg
    class Error < StandardError; end

    # The NVENC failure fallback, in order. A requested "libx264"/"copy" profile has
    # no fallback (the user asked for it explicitly).
    NVENC_FALLBACK = %w[nvenc libx264].freeze

    def initialize(
      shell: Shell.new,
      ffmpeg_cmd: self.class.default_ffmpeg_cmd,
      ffprobe_cmd: self.class.default_ffprobe_cmd,
      nvenc_cq: self.class.default_nvenc_cq,
      x264_crf: self.class.default_x264_crf,
      audio_bitrate: self.class.default_audio_bitrate
    )
      @shell = shell
      @ffmpeg_cmd = ffmpeg_cmd
      @ffprobe_cmd = ffprobe_cmd
      @nvenc_cq = nvenc_cq
      @x264_crf = x264_crf
      @audio_bitrate = audio_bitrate
    end

    def self.default_ffmpeg_cmd = (ENV["FFMPEG_CMD"] || "ffmpeg").split
    def self.default_ffprobe_cmd = (ENV["FFPROBE_CMD"] || "ffprobe").split
    def self.default_encoder = ENV["RENDER_ENCODER"].presence || "nvenc"
    def self.default_nvenc_cq = (ENV["RENDER_NVENC_CQ"].presence || "19").to_i
    def self.default_x264_crf = (ENV["RENDER_X264_CRF"].presence || "18").to_i
    def self.default_audio_bitrate = ENV["RENDER_AUDIO_BITRATE"].presence || "192k"

    # Whether FFmpeg lists the `h264_nvenc` encoder at all (a cheap pre-check).
    def nvenc_listed?
      @shell.capture([ *@ffmpeg_cmd, "-hide_banner", "-encoders" ]).include?("h264_nvenc")
    rescue Shell::CommandError, Errno::ENOENT
      false
    end

    # Re-encode (or copy) the section into `out`. Returns [encoder_used, warning].
    #
    # NVENC is tried first for the "nvenc" profile; a failure falls back to libx264
    # with a slowness warning. "libx264" and "copy" have no fallback. `local_start`/
    # `local_dur` are relative to the section file (its local time 0 = the source
    # time `dl_start`); the re-encode makes the cut frame-exact.
    def encode_clip(section, out, local_start:, local_dur:, profile:)
      out = Pathname(out)
      out.dirname.mkpath

      if profile == "copy"
        @shell.run(build_encode_cmd(section, out, local_start:, local_dur:, encoder: "copy"))
        return [ "copy", nil ]
      end

      order = profile == "nvenc" ? NVENC_FALLBACK : [ profile ]
      last = nil
      order.each do |encoder|
        @shell.run(build_encode_cmd(section, out, local_start:, local_dur:, encoder:))
        warning = nil
        unless encoder == profile
          warning = "NVENC unavailable — fell back to #{encoder} (slower software encode)."
          Rails.logger.warn(warning)
        end
        return [ encoder, warning ]
      rescue StandardError => e
        last = e
        Rails.logger.warn("Encoder #{encoder} failed: #{e.message}")
      end
      raise Error, "Failed to encode the clip with #{order.inspect}. Last error: #{last}"
    end

    # The clip's duration in seconds (0.0 if unparseable).
    def probe_duration(clip)
      out = @shell.capture([
        *@ffprobe_cmd, "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", clip.to_s
      ])
      Float(out.to_s.strip)
    rescue ArgumentError, TypeError
      0.0
    end

    # Extract `count` candidate frames from `clip_path` into `out_dir`, returning
    # the ordered `frame-NNN.jpg` filenames. Scene-change frames first, then
    # evenly-spaced samples fill the remainder, so even a flat clip yields `count`.
    # Pay-once: an existing full set is returned untouched unless `regenerate`.
    # NO LLM is involved — extraction is deterministic and free.
    def extract_frames(clip_path, out_dir, count:, scene_threshold:, regenerate: false)
      out_dir = Pathname(out_dir)
      out_dir.mkpath
      existing = Pathname.glob(out_dir.join("frame-*.jpg")).sort
      return existing.first(count).map { |p| p.basename.to_s } if !regenerate && existing.size >= count

      clear_frame_files(out_dir)

      # Pass 1: scene-change candidates (best-effort — a flat clip yields none).
      begin
        @shell.run(build_scene_cmd(clip_path, out_dir.join("scene-%03d.jpg").to_s, scene_threshold))
      rescue StandardError => e
        Rails.logger.warn("frames: scene detection failed (#{e.message}) — using samples only")
      end

      frames = promote_scenes(out_dir, count)

      # Pass 2: fill the remainder with evenly-spaced samples.
      remaining = count - frames.size
      if remaining.positive?
        duration = probe_duration(clip_path)
        sample_timestamps(duration, remaining).each do |ts|
          dest = out_dir.join(format("frame-%03d.jpg", frames.size + 1))
          @shell.run(build_sample_cmd(clip_path, dest, ts))
          frames << dest
        end
      end

      Pathname.glob(out_dir.join("scene-*.jpg")).each { |p| p.delete }
      frames.map { |p| p.basename.to_s }
    end

    private

    def build_encode_cmd(section, out, local_start:, local_dur:, encoder:)
      base = [
        *@ffmpeg_cmd, "-nostdin", "-hide_banner", "-loglevel", "error", "-stats", "-y",
        "-ss", format("%.3f", local_start), "-i", section.to_s, "-t", format("%.3f", local_dur)
      ]
      return [ *base, "-c", "copy", "-movflags", "+faststart", out.to_s ] if encoder == "copy"

      vcodec =
        if encoder == "libx264"
          [ "-c:v", "libx264", "-preset", "medium", "-crf", @x264_crf.to_s, "-pix_fmt", "yuv420p" ]
        else
          [ "-c:v", "h264_nvenc", "-preset", "p5", "-tune", "hq", "-rc", "vbr",
            "-cq", @nvenc_cq.to_s, "-b:v", "0", "-pix_fmt", "yuv420p" ]
        end
      [ *base, *vcodec, "-c:a", "aac", "-b:a", @audio_bitrate, "-movflags", "+faststart", out.to_s ]
    end

    def build_scene_cmd(clip, out_pattern, threshold)
      [
        *@ffmpeg_cmd, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", clip.to_s,
        "-vf", "select='gt(scene,#{format('%.3f', threshold)})'",
        "-vsync", "vfr", "-frames:v", "50", "-q:v", "3", out_pattern
      ]
    end

    def build_sample_cmd(clip, out, timestamp)
      [
        *@ffmpeg_cmd, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", format("%.3f", timestamp), "-i", clip.to_s, "-frames:v", "1", "-q:v", "3", out.to_s
      ]
    end

    def clear_frame_files(out_dir)
      (Pathname.glob(out_dir.join("frame-*.jpg")) + Pathname.glob(out_dir.join("scene-*.jpg")))
        .each { |p| p.delete }
    end

    # Rename the first `count` scene captures to `frame-NNN.jpg`, in order.
    def promote_scenes(out_dir, count)
      Pathname.glob(out_dir.join("scene-*.jpg")).sort.first(count).map.with_index do |scene, i|
        dest = out_dir.join(format("frame-%03d.jpg", i + 1))
        scene.rename(dest)
        dest
      end
    end

    # `count` evenly-spaced interior timestamps of a clip of `duration`.
    def sample_timestamps(duration, count)
      return [] if count <= 0
      return Array.new(count, 0.0) if duration <= 0

      (0...count).map { |i| duration * (i + 1) / (count + 1) }
    end
  end
end
