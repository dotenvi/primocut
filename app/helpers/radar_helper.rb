module RadarHelper
  # A Radar path that keeps the current filter and the OTHER feed's page, so
  # paging "New" never resets "Earlier". Page 1 is the default and stays out of
  # the query string, keeping the unpaged url clean.
  #
  # NOTE: `root` is the Radar, so no route helper named `radar_path` exists today.
  # If one is ever added, this shadows it — rename this, not the route.
  def radar_path(project: nil, new_page: 1, seen_page: 1)
    root_path(**{ project_id: project&.id, new_page: (new_page if new_page > 1),
                  seen_page: (seen_page if seen_page > 1) }.compact)
  end
end
