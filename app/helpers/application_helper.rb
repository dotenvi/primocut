module ApplicationHelper
  # Width policy, ported from the PoC `App.svelte`: the canvas is generous by
  # default so large screens get used, and only reading or table-oriented screens
  # opt back into the comfortable measure — long prose and wide tables read worse
  # when they sprawl.
  #
  # Sources is deliberately absent from this list. It keeps its own comfortable
  # measure while the pipeline panel is closed and gives it up when the panel
  # opens, so the table and the panel fit on one line; that decision belongs to
  # the screen, not here.
  READING_SCREENS = %w[radar activity niche videos channels settings].freeze

  def content_width
    READING_SCREENS.include?(controller_name) ? "max-w-[1160px]" : "max-w-[1680px]"
  end
end
