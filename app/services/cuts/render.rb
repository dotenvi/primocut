require "pathname"
require "tmpdir"

module Cuts
  # Render the clips of a cut's items: section download (yt-dlp) + FFmpeg re-encode.
  # Ported from the PoC `worker/render_jobs.py`. Runs in the BACKGROUND (its job is
  # on the default queue), so the UI keeps letting the user triage while clips
  # render. Two invariants carried over:
  #
  # - Per-item isolation: a clip that fails is logged, its row marked `error` with
  #   the message (what the UI renders), and the batch moves on — one bad item never
  #   wastes the others.
  # - Pay-once cache: an item already `done` with the same `params_hash` (range +
  #   padding + encode profile + tolerance) is skipped unless `regenerate`. A pure
  #   reorder (same params, new position) renames the existing MP4 without encoding.
  #
  # The section is an EPHEMERAL intermediate (a throwaway temp dir, discarded when
  # the item is done); the clip MP4 is the permanent deliverable, laid out under
  # `<clips_dir>/<youtube_id>/<cut_id>/NNN-slug.mp4`.
  #
  # `aligner` is the optional surgical boundary-refinement seam (the WhisperX pass
  # of the PoC): when present, the item's `[start, end]` is nudged to the nearest
  # word edge and the clip passes through the `aligning` state; when nil (the
  # default, no align backend configured) the item goes straight to `cutting`,
  # exactly as the PoC does with `align_python` unset.
  class Render
    Result = Data.define(:cut, :rendered, :skipped, :failed)

    def initialize(
      ytdlp: Adapters::Ytdlp.new,
      ffmpeg: Adapters::Ffmpeg.new,
      clips_dir: self.class.default_clips_dir,
      encoder: Adapters::Ffmpeg.default_encoder,
      section_margin_s: self.class.default_section_margin_s,
      aligner: nil
    )
      @ytdlp = ytdlp
      @ffmpeg = ffmpeg
      @clips_root = Pathname(clips_dir)
      @encoder = encoder
      @margin = section_margin_s
      @aligner = aligner
    end

    def self.default_clips_dir = ENV["CLIPS_DIR"].presence || Rails.root.join("clips").to_s
    def self.default_section_margin_s = (ENV["RENDER_SECTION_MARGIN_S"].presence || "15").to_f

    # Render each requested item's clip (all of the cut's items when `item_ids` is
    # nil), with per-item isolation and the pay-once cache.
    def call(cut, item_ids: nil, regenerate: false, fast_copy: false)
      profile = fast_copy ? "copy" : @encoder
      video = cut.source_video
      url = video.url.presence || "https://www.youtube.com/watch?v=#{video.youtube_id}"
      duration = video.duration_s.to_f

      items = cut.cut_items.order(:position)
      items = items.where(id: item_ids) if item_ids

      rendered = skipped = failed = 0
      items.each do |item|
        if render_one(item, cut:, video:, url:, duration:, profile:, regenerate:)
          rendered += 1
        else
          skipped += 1
        end
      rescue StandardError => e # per-item isolation: log, record, keep going
        Rails.logger.error("render: item #{item.id} of cut #{cut.id} failed: #{e.message}")
        failed += 1
        flag_failure(item, e)
      end

      Rails.logger.info("render(cut #{cut.id}) done: #{rendered} rendered, #{skipped} cached, #{failed} failed")
      build_master(cut)
      Result.new(cut:, rendered:, skipped:, failed:)
    end

    private

    # Concatenate the finished clips into the cut's master — seconds of stream copy
    # at the end of minutes of encoding, and what the room actually plays. Degradable
    # on purpose: the clips are the deliverables and they are already on disk, so a
    # failure here must not turn a good render into a failed one.
    def build_master(cut)
      Master.new(ffmpeg: @ffmpeg, clips_dir: @clips_root.to_s).build(cut)
    rescue StandardError => e
      Rails.logger.error("render(cut #{cut.id}): the clips are fine but the master failed: #{e.message}")
      nil
    end

    # Render one item. Returns true if it re-encoded, false if the cache served it.
    def render_one(item, cut:, video:, url:, duration:, profile:, regenerate:)
      position = item.position
      start_s = item.start_s.to_f
      end_s = item.end_s.to_f
      title = item.topic&.title.presence || "Manual range"
      filename = Naming.clip_filename(position, title)
      rel_path = "#{video.youtube_id}/#{cut.id}/#{filename}"
      dest = @clips_root.join(rel_path)
      tolerance = @aligner ? @aligner.tolerance_s : 0.0
      phash = Clip.params_hash(start_s, end_s, @margin, profile, tolerance)

      existing = item.clip
      if !regenerate && existing&.state_done? && existing.params_hash == phash &&
         @clips_root.join(existing.rel_path).exist?
        return serve_from_cache(existing, dest:, rel_path:, filename:, position:)
      end

      clip = reset_to_queued(item, video:, cut:, position:, filename:, rel_path:, phash:, profile:, start_s:, end_s:)
      encode(clip, url:, duration:, start_s:, end_s:, profile:, dest:, rel_path:, filename:, position:)
      true
    end

    # A pure reorder (same params, new position) renames the deliverable to the new
    # NNN-slug.mp4 with no re-encode, keeping the cache valid.
    def serve_from_cache(clip, dest:, rel_path:, filename:, position:)
      old = @clips_root.join(clip.rel_path)
      if clip.rel_path != rel_path
        dest.dirname.mkpath
        old.rename(dest)
      end
      clip.update!(state: "done", position:, filename:, rel_path:)
      Rails.logger.info("render: item #{clip.cut_item_id} served from cache (#{rel_path})")
      false
    end

    def reset_to_queued(item, video:, cut:, position:, filename:, rel_path:, phash:, profile:, start_s:, end_s:)
      clip = Clip.find_or_initialize_by(cut_item_id: item.id)
      clip.update!(
        source_video_id: video.id, cut_id: cut.id, position:, filename:, rel_path:,
        params_hash: phash, padding_s: @margin, encode_profile: profile,
        start_s:, end_s:, state: "queued", error: "", encoder_used: "",
        size_bytes: 0, duration_s: end_s - start_s
      )
      clip
    end

    def encode(clip, url:, duration:, start_s:, end_s:, profile:, dest:, rel_path:, filename:, position:)
      clip.update!(state: "downloading_section")
      # The section is ephemeral: temp dir, discarded when the item is done.
      Dir.mktmpdir("primocut-clip-") do |tmp|
        section = @ytdlp.download_section(url, tmp, start_s:, end_s:, margin_s: @margin, duration:)
        # `--force-keyframes-at-cuts` makes the section span EXACTLY [dl_start,
        # dl_end], so its local time 0 is the source time dl_start — the section's
        # origin on the source-video timeline. Everything downstream offsets from s0.
        s0, = Adapters::Ytdlp.section_bounds(start_s, end_s, @margin, duration)

        r_start, r_end = refine(clip, section:, s0:, start_s:, end_s:, workdir: tmp)
        local_start = [ 0.0, r_start - s0 ].max
        local_dur = r_end - r_start

        clip.update!(state: "cutting")
        encoder_used, warning = @ffmpeg.encode_clip(section, dest, local_start:, local_dur:, profile:)
        finalize(clip, dest:, rel_path:, filename:, position:, encoder_used:, warning:, r_start:, r_end:, local_dur:)
      end
    end

    # The surgical boundary refinement, when an aligner is configured — a silent
    # fallback to the original bounds on any failure (refinement never blocks).
    def refine(clip, section:, s0:, start_s:, end_s:, workdir:)
      return [ start_s, end_s ] unless @aligner

      clip.update!(state: "aligning")
      @aligner.refine_bounds(section:, s0:, start_s:, end_s:, workdir:)
    rescue StandardError => e
      Rails.logger.warn("align: failed (#{e.message}); keeping original bounds.")
      [ start_s, end_s ]
    end

    def finalize(clip, dest:, rel_path:, filename:, position:, encoder_used:, warning:, r_start:, r_end:, local_dur:)
      size = dest.exist? ? dest.size : 0
      clip.update!(
        state: "done", encoder_used:, size_bytes: size, rel_path:, filename:, position:,
        # The EFFECTIVE window actually encoded (refined when alignment ran); the
        # export SRT/manifest read these, not the request.
        render_start_s: r_start, render_end_s: r_end, duration_s: local_dur, error: warning.to_s
      )
      Rails.logger.info("render: item #{clip.cut_item_id} done -> #{rel_path} (#{encoder_used}, #{size} bytes)")
    end

    # Record the failure on the clip row (what the UI renders). A clip we cannot
    # even flag must not abort the batch.
    def flag_failure(item, error)
      # Query fresh: the item's `clip` association may be a cached nil from before
      # reset_to_queued created the row.
      clip = Clip.find_by(cut_item_id: item.id)
      clip&.update!(state: "error", error: error.message)
    rescue StandardError => e
      Rails.logger.error("render: could not record failure of item #{item.id}: #{e.message}")
    end
  end
end
