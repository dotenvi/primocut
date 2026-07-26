module NavigationHelper
  # The single back link at the top of a screen: where it was opened FROM when
  # that is known, and its place in the hierarchy otherwise.
  #
  # The video screen has four entry points and the hierarchy serves one of them,
  # so arriving from the Radar and leaving through the breadcrumb drops you on a
  # channel you never visited — and loses your place in the feed.
  #
  # The origin travels as structured params (a whitelisted key, a flag and page
  # numbers) and the path is REBUILT here. Nothing from the query string is ever
  # used as a destination: a raw path would let a crafted url aim this link
  # off-site, and `request.referer` would break on refresh, vanish under privacy
  # settings and make the page render differently per header, which fights Turbo's
  # cache.
  BACK_LINK_CLASS = "eyebrow cursor-pointer hover:text-ink-2 mb-2 block no-underline".freeze

  def back_link(project, to:, label:)
    origin_back_link(project) || link_to(label, to, class: BACK_LINK_CLASS)
  end

  private

  def origin_back_link(project)
    case params[:from]
    when "radar" then link_to "‹ Radar", radar_origin_path(project), class: BACK_LINK_CLASS
    when "niche" then link_to "‹ Niche / outliers", niche_origin_path(project), class: BACK_LINK_CLASS
    end
  end

  # `rf` is a flag, not an id: a filtered Radar can only have linked to a video
  # through the project it was filtered by, which is the project already on this
  # screen — so the filter is restored without trusting (or looking up) an id.
  def radar_origin_path(project)
    radar_path(project: (project if params[:rf].present?),
               new_page: origin_page(:np), seen_page: origin_page(:sp))
  end

  def niche_origin_path(project)
    fmt = params[:fmt].presence_in(Niche::Screen::FORMATS) || Niche::Screen::FORMATS.first
    project_niche_path(project, tab: "outliers", fmt: fmt)
  end

  # Junk ("abc", "-9", nil) reads as the first page rather than raising or paging
  # into nothing.
  def origin_page(key) = [ params[key].to_i, 1 ].max
end
