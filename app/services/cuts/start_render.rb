module Cuts
  # Render the cut's clips in the background. The cut is marked `rendering` up
  # front for the same reason the analysis marks its video: the mark is what the
  # screen polls on.
  class StartRender
    def call(cut:)
      cut.update!(status: "rendering")
      CutRenderJob.perform_later(cut.id)
      cut
    end
  end
end
