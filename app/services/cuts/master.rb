module Cuts
  # The cut as ONE file: its rendered clips concatenated in composition order, with
  # no seams. This is what the room plays.
  #
  # It is built with a concat-demuxer STREAM COPY, so it is not a second encode —
  # the clips' bytes are remounted in order. Measured on a 6-item, 13-minute cut:
  # ~4 seconds for 1.3 GB. That is why playing this beats chaining the clips in the
  # browser, where every item boundary costs a file load.
  #
  # The filename carries a digest of the composition it was built from, so a master
  # is only ever served for the cut that is actually on screen: reorder an item, or
  # re-render one with different parameters, and the digest no longer matches — the
  # stale file is not mistaken for the current one. Same idea as `Clip#params_hash`,
  # one level up.
  class Master
    class NotReady < StandardError; end

    def initialize(ffmpeg: Adapters::Ffmpeg.new, clips_dir: Render.default_clips_dir)
      @ffmpeg = ffmpeg
      @clips_root = Pathname(clips_dir)
    end

    # The path, or nil when this composition has no master on disk. The screen asks
    # with this before offering playback at all.
    def path_for(cut)
      items = ordered_items(cut)
      return nil unless complete?(items)

      path = path_of(cut, items)
      path.exist? ? path : nil
    end

    def call(cut:)
      path_for(cut) or raise NotReady, "This cut has no master yet — render it first."
    end

    # Build it, unless the current composition's master is already there. Returns the
    # path, or nil when the cut is not fully rendered (a master missing an item would
    # silently misrepresent the composition).
    def build(cut)
      items = ordered_items(cut)
      return nil unless complete?(items)

      out = path_of(cut, items)
      return out if out.exist?

      dir = @clips_root.join(File.dirname(items.first.clip.rel_path))
      @ffmpeg.concat_master(items.map { |i| File.basename(i.clip.rel_path) }, out, cwd: dir)
      prune_stale(dir, keep: out)
      Rails.logger.info("master(cut #{cut.id}) built: #{out.basename} (#{out.size} bytes)")
      out
    end

    private

    def ordered_items(cut) = cut.cut_items.order(:position).includes(:clip).to_a

    # Every item, or none: a master is the whole composition by definition.
    def complete?(items)
      items.any? && items.all? { |i| i.clip&.state_done? && i.clip.rel_path.present? }
    end

    def path_of(cut, items)
      @clips_root.join(File.dirname(items.first.clip.rel_path), "master-#{digest(items)}.mp4")
    end

    # The composition's identity: which clips, in which order, at which parameters.
    def digest(items)
      Digest::SHA1.hexdigest(items.map { |i| "#{i.position}|#{i.clip.params_hash}" }.join("\n"))[0, 12]
    end

    # A superseded master is dead weight measured in gigabytes, so it goes as soon as
    # the new one is in place.
    def prune_stale(dir, keep:)
      Pathname.glob(dir.join("master-*.mp4")).each do |old|
        next if old == keep

        old.delete
        Rails.logger.info("master: removed the superseded #{old.basename}")
      rescue SystemCallError => e
        Rails.logger.warn("master: could not remove #{old.basename}: #{e.message}")
      end
    end
  end
end
