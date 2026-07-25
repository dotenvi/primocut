require "pathname"
require "fileutils"
require "zip"

module Cuts
  # Export a cut into a deliverable bundle on disk. Ported from the PoC
  # `worker/export_jobs.py`. Assembles the cut's rendered clips (COPIED, never
  # moved — the originals under `clips_dir` are untouched) into a timestamped
  # package dir under `exports_dir`, with a per-clip SRT, a concat master (stream
  # copy by default) and the two manifests, optionally zipped.
  #
  # Un-rendered items: by default the export FAILS with a clear message listing
  # them (an export packages existing deliverables). `render_missing: true` renders
  # the missing items first (reusing the render service) and then packages.
  #
  # Business failures (unrendered items, a bad flag combo) are recorded on the
  # export row and returned as an error Result; only an unexpected error (FFmpeg/IO)
  # re-raises, after marking the row. The model is referenced as `::Export` — inside
  # `Cuts`, the bare `Export` would resolve to this service.
  class Export
    Result = Data.define(:cut, :state, :item_count, :package_rel_path, :zip_rel_path,
                         :master, :upscaled, :error)

    def initialize(
      ffmpeg: Adapters::Ffmpeg.new,
      clips_dir: Cuts::Render.default_clips_dir,
      exports_dir: self.class.default_exports_dir,
      render_service: nil,
      clock: -> { Time.current }
    )
      @ffmpeg = ffmpeg
      @clips_root = Pathname(clips_dir)
      @exports_root = Pathname(exports_dir)
      @render_service = render_service
      @clock = clock
    end

    def self.default_exports_dir = ENV["EXPORTS_DIR"].presence || Rails.root.join("exports").to_s

    def call(cut, render_missing: false, skip_master: false, upscale: false, make_zip: true)
      items = load_items(cut)
      reset_row(cut, item_count: items.size, skip_master:, upscaled: upscale)

      return failure(cut, "--upscale needs the master; it cannot be combined with skipping the master.") if upscale && skip_master
      return failure(cut, "the cut has no items to export.") if items.empty?

      items = resolve_missing(cut, items, render_missing:)
      return items if items.is_a?(Result) # a failure short-circuited

      begin
        package(cut, items, skip_master:, upscale:, make_zip:)
      rescue StandardError => e # unexpected (FFmpeg/IO) — record and re-raise
        Rails.logger.error("export(cut #{cut.id}) failed: #{e.message}")
        row(cut).update!(state: "error", error: e.message)
        raise
      end
    end

    private

    # Snapshot the ordered items into plain hashes (so the file IO reads no
    # associations mid-loop): title, kind, the clip's state and effective bounds.
    def load_items(cut)
      cut.cut_items.order(:position).includes(:clip, :topic).map do |it|
        clip = it.clip
        { item_id: it.id, position: it.position, topic_id: it.topic_id,
          title: it.topic&.title.presence || "Manual range",
          kind: it.topic_id ? "topic" : "manual",
          clip: clip && clip_snapshot(clip) }
      end
    end

    def clip_snapshot(clip)
      has_eff = clip.render_end_s > clip.render_start_s
      { state: clip.state, rel_path: clip.rel_path,
        eff_start: has_eff ? clip.render_start_s : clip.start_s,
        eff_end: has_eff ? clip.render_end_s : clip.end_s }
    end

    def missing_ids(items)
      items.reject { |it| it[:clip] && it[:clip][:state] == "done" }.map { |it| it[:item_id] }
    end

    def resolve_missing(cut, items, render_missing:)
      missing = missing_ids(items)
      return items if missing.empty?

      unless render_missing
        return failure(cut, "#{missing.size} item(s) not rendered: #{missing.map { |i| "##{i}" }.join(', ')}. " \
                            "Render them first, or export with render_missing.")
      end

      Rails.logger.info("export(cut #{cut.id}): rendering #{missing.size} missing item(s) first")
      (@render_service || Cuts::Render.new).call(cut, item_ids: missing)
      items = load_items(cut)
      still = missing_ids(items)
      return items if still.empty?

      failure(cut, "#{still.size} item(s) still not rendered after the render pass: #{still.map { |i| "##{i}" }.join(', ')}.")
    end

    def package(cut, items, skip_master:, upscale:, make_zip:)
      row(cut).update!(state: "packaging")
      video = cut.source_video
      segments = video.transcript&.segments || []

      moment = @clock.call.utc
      pkg_rel = "#{video.youtube_id}/#{cut.id}/#{Naming.slugify(cut.name)}-#{moment.strftime('%Y%m%d-%H%M%S')}"
      pkg_dir = @exports_root.join(pkg_rel)
      pkg_dir.mkpath

      mp4_names, items_meta = write_clips(items, pkg_dir, segments)
      master_info = build_master(mp4_names, pkg_dir, skip_master:, upscale:)
      write_manifests(video, cut, items_meta, master_info, pkg_dir, moment.iso8601)
      zip_rel = make_zip ? zip_bundle(pkg_dir, pkg_rel) : ""

      row(cut).update!(state: "done", package_rel_path: pkg_rel, zip_rel_path: zip_rel, error: "")
      Rails.logger.info("export(cut #{cut.id}) done: #{items.size} item(s) -> #{pkg_rel}")
      Result.new(cut:, state: "done", item_count: items.size, package_rel_path: pkg_rel,
                 zip_rel_path: zip_rel, master: !master_info.nil?, upscaled: upscale, error: nil)
    end

    # Copy each clip (in composition order) + write its SRT, at export-time NNN.
    def write_clips(items, pkg_dir, segments)
      mp4_names = []
      items_meta = items.each_with_index.map do |it, position|
        clip = it[:clip]
        mp4_name = Naming.clip_export_name(position, it[:title], "mp4")
        srt_name = Naming.clip_export_name(position, it[:title], "srt")
        FileUtils.cp(@clips_root.join(clip[:rel_path]).to_s, pkg_dir.join(mp4_name).to_s) # never move the original
        start = clip[:eff_start]
        finish = clip[:eff_end]
        pkg_dir.join(srt_name).write(Srt.for_clip(segments, start, finish))
        mp4_names << mp4_name
        { "position" => position + 1, "mp4" => mp4_name, "srt" => srt_name,
          "title" => it[:title], "kind" => it[:kind], "topic_id" => it[:topic_id],
          "start_s" => start, "end_s" => finish, "duration_s" => [ 0.0, finish - start ].max,
          "packaging" => empty_packaging }
      end
      [ mp4_names, items_meta ]
    end

    # Present-but-empty so the manifest shape is stable; the packaging step fills it.
    def empty_packaging
      { "titles" => [], "thumbnail_brief" => "", "frames" => [], "best_frame" => "" }
    end

    def build_master(mp4_names, pkg_dir, skip_master:, upscale:)
      return nil if skip_master

      @ffmpeg.concat_master(mp4_names, pkg_dir.join("master.mp4"), cwd: pkg_dir, upscale:)
      { "filename" => "master.mp4", "upscaled" => upscale,
        "resolution" => upscale ? "#{@ffmpeg.upscale_height}p" : "original" }
    end

    def write_manifests(video, cut, items_meta, master_info, pkg_dir, generated_at)
      data = Manifest.data(video:, cut:, items: items_meta, master: master_info, generated_at:)
      pkg_dir.join("manifest.json").write(Manifest.to_json_text(data))
      pkg_dir.join("manifest.md").write(Manifest.to_markdown(data))
    end

    def zip_bundle(pkg_dir, pkg_rel)
      zip_path = @exports_root.join("#{pkg_rel}.zip")
      zip_path.delete if zip_path.exist?
      Zip::File.open(zip_path.to_s, create: true) do |zip|
        pkg_dir.glob("**/*").reject(&:directory?).each do |entry|
          zip.add(entry.relative_path_from(pkg_dir).to_s, entry.to_s)
        end
      end
      "#{pkg_rel}.zip"
    end

    def row(cut)
      ::Export.find_or_create_by!(cut:) { |e| e.source_video_id = cut.source_video_id }
    end

    def reset_row(cut, item_count:, skip_master:, upscaled:)
      row(cut).update!(source_video_id: cut.source_video_id, state: "queued", error: "",
                       item_count:, skip_master:, upscaled:, package_rel_path: "", zip_rel_path: "")
    end

    def failure(cut, message)
      Rails.logger.warn("export(cut #{cut.id}): #{message}")
      row(cut).update!(state: "error", error: message)
      Result.new(cut:, state: "error", item_count: row(cut).item_count, package_rel_path: "",
                 zip_rel_path: "", master: false, upscaled: false, error: message)
    end
  end
end
