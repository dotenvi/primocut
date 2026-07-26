module Radar
  # One feed's page: the visible slice plus the state its pager needs. A feed
  # shrinks between requests (a crossing gets marked seen, a channel is dropped),
  # so an out-of-range page clamps to the last one rather than rendering empty or
  # 404ing on a link the user legitimately followed.
  class Page
    attr_reader :rows, :current, :total_pages, :total_count

    def initialize(rows, page:, per_page:)
      @total_count = rows.size
      @total_pages = [ (rows.size.to_f / per_page).ceil, 1 ].max
      @current = page.to_i.clamp(1, @total_pages)
      @rows = rows[(@current - 1) * per_page, per_page] || []
    end

    def any? = @rows.any?
    def paged? = @total_pages > 1
  end
end
