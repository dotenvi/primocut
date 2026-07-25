namespace :primocut do
  desc "Validate the environment (GPU, FFmpeg, yt-dlp, sidecar, LLM key, YouTube, DB)."
  task doctor: :environment do
    healthy = Diagnostics::TablePrinter.new.call(Diagnostics::Report.new.call)
    exit 1 unless healthy
  end
end
