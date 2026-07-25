# Regenerate a source video's topics in the background (the LLM MACRO pass). Thin:
# delegate to Cuts::Selection. On the default queue — it is network-bound (LLM),
# not GPU-bound, so it does not serialize on the `gpu` queue.
#
# The Cut Room flips the video to "analyzing" before enqueuing so its topics frame
# polls; here we restore "done" when the pass finishes (only if we still own that
# transient state, so a real pipeline status is never clobbered).
class AnalyzeTopicsJob < ApplicationJob
  queue_as :default

  def perform(source_video_id, service: Cuts::Selection.new)
    source_video = SourceVideo.find(source_video_id)
    service.call(source_video)
  ensure
    source_video&.update!(status: "done") if source_video&.status == "analyzing"
  end
end
