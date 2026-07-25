# Regenerate a source video's topics in the background (the LLM MACRO pass). Thin:
# delegate to Cuts::Selection. On the default queue — it is network-bound (LLM),
# not GPU-bound, so it does not serialize on the `gpu` queue.
class AnalyzeTopicsJob < ApplicationJob
  queue_as :default

  def perform(source_video_id, service: Cuts::Selection.new)
    source_video = SourceVideo.find(source_video_id)
    service.call(source_video)
  end
end
