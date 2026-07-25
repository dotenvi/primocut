require "thor"
require "json"
require "tmpdir"

module Primocut
  # The `bin/primocut` command line — the testing workflows driven from the
  # terminal (docs §4, Phase 6). It is deliberately thin: each command parses
  # arguments and calls an already-tested service, exactly like a controller. The
  # product flows live in the web UI; this exists to exercise the pipeline, run a
  # snapshot cycle, dump a metrics payload for parity checks, and export a cut,
  # without a browser. `doctor` is a rake task (`rake primocut:doctor`), not here.
  class Cli < Thor
    def self.exit_on_failure? = true

    desc "pipeline URL", "Run the source-video pipeline inline (metadata → audio → transcription → chat)"
    long_desc <<~DESC
      Runs the same Pipeline::Runner the job uses, but with the log reporter (no
      progress rows, no GPU queue). Persists the transcript and chat signal to the
      database and reuses them on re-run (the pay-once cache). Use it to process one
      source video from the terminal — the CLI half of the one-pipeline invariant.
    DESC
    option :project, aliases: "-p", type: :numeric, required: true, desc: "Project ID to contain the video"
    def pipeline(url)
      project = Project.find(options[:project])
      url = Adapters::Ytdlp.validate_youtube_url(url)
      youtube_id = Adapters::Ytdlp.extract_video_id(url)

      source_video = project.source_videos.find_or_initialize_by(youtube_id:)
      source_video.assign_attributes(url:, status: "queued")
      source_video.save!

      Dir.mktmpdir("primocut-cli-") do |audio_dir|
        result = Pipeline::Runner.new.call(source_video, reporter: Pipeline::LogReporter.new, audio_dir:)
        say "Done #{source_video.youtube_id}: #{result.transcript.segments.size} segment(s), " \
            "#{result.chat_signal&.peaks&.size || 0} chat peak(s).", :green
        result.warnings.each { |w| say "  warn: #{w}", :yellow }
      end
    rescue ActiveRecord::RecordNotFound
      abort_with "Project ##{options[:project]} not found."
    rescue Adapters::Ytdlp::Error => e
      abort_with "Invalid URL: #{e.message}"
    rescue Pipeline::Error => e
      abort_with "Essential stage failed: #{e.message}"
    end

    desc "snapshot", "Run one competitor snapshot cycle inline (no scheduler/worker)"
    option :scope, type: :string, default: "all", desc: "all | recent (< recent_days)"
    option :channel, aliases: "-c", type: :string, desc: "Limit to a single channel ID (UC…)"
    def snapshot
      result = Competitors::SnapshotCycle
               .new(client: Adapters::YoutubeApi.from_env)
               .call(scope: options[:scope], channel_id: options[:channel])
      say "Snapshot (#{result[:scope]}) done: #{result[:channels]} channel(s), " \
          "#{result[:videos]} video(s), #{result[:packaging_changes]} packaging change(s), " \
          "#{result[:comments]} comment set(s), #{result[:quota_units]} quota unit(s).", :green
    rescue ArgumentError => e
      abort_with e.message
    rescue Adapters::YoutubeApi::Error => e
      abort_with "Snapshot failed: #{e.message}"
    end

    desc "metrics", "Print a dashboard payload as JSON (for numeric parity vs. the PoC)"
    option :project, aliases: "-p", type: :numeric, desc: "Project (niche) dashboard"
    option :channel, aliases: "-c", type: :string, desc: "Channel dashboard (UC…)"
    option :video, aliases: "-v", type: :string, desc: "Video report (with --channel)"
    def metrics
      data = metrics_payload
      puts JSON.pretty_generate(data.as_json)
    rescue ActiveRecord::RecordNotFound
      abort_with "Not found."
    end

    desc "export", "Export a cut into a deliverable bundle (clips + SRT + master + manifests)"
    option :cut, aliases: "-c", type: :numeric, required: true, desc: "Cut ID to export"
    option :render_missing, type: :boolean, default: false, desc: "Render un-rendered items first"
    option :skip_master, type: :boolean, default: false, desc: "Do not build the concat master"
    option :upscale, type: :boolean, default: false, desc: "Re-encode the master to 1440p (NVENC)"
    option :zip, type: :boolean, default: true, desc: "Also write the .zip (use --no-zip to skip)"
    def export
      cut = Cut.find(options[:cut])
      result = Cuts::Export.new.call(
        cut, render_missing: options[:render_missing], skip_master: options[:skip_master],
             upscale: options[:upscale], make_zip: options[:zip]
      )
      if result.state == "done"
        say "Exported #{result.item_count} clip(s) to:", :green
        say "  #{result.package_rel_path}"
        say "  #{result.zip_rel_path}" if result.zip_rel_path
      else
        abort_with "Export failed: #{result.error}"
      end
    rescue ActiveRecord::RecordNotFound
      abort_with "Cut ##{options[:cut]} not found."
    end

    private

    def metrics_payload
      if options[:project]
        Metrics::NicheDashboard.new(Project.find(options[:project])).call
      elsif options[:channel] && options[:video]
        channel = CompetitorChannel.find_by!(youtube_channel_id: options[:channel])
        video = channel.competitor_videos.find_by!(youtube_video_id: options[:video])
        Metrics::VideoReport.new(video).call
      elsif options[:channel]
        Metrics::ChannelDashboard.new(CompetitorChannel.find_by!(youtube_channel_id: options[:channel])).call
      else
        abort_with "Pass --project, --channel, or --channel + --video."
      end
    end

    # Print a message to stderr and exit non-zero. `exit_on_failure?` makes Thor
    # surface this as a proper CLI failure.
    def abort_with(message)
      say message, :red
      exit 1
    end
  end
end
