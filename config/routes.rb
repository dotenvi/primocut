Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Global navigation (cross-project) — the IA's top level.
  root "radar#show"
  get "activity", to: "activity#show"

  # Per-project navigation. Real content lands in Phase 2; these render shell
  # placeholders for now so the navigation is walkable end to end.
  scope "projects/:project_id", as: :project do
    get  "sources",     to: "sources#index",  as: :sources
    post "sources",     to: "sources#create"
    get  "sources/:id", to: "sources#show",   as: :source # single-row polling frame

    # The Cut Room, per source video. Built section by section: topics + triage first.
    get  "sources/:source_video_id/cut_room", to: "cuts#show", as: :cut_room
    get  "sources/:source_video_id/topics", to: "cuts#topics", as: :topics # live-progress frame
    post "sources/:source_video_id/topics/analyze", to: "cuts#analyze_topics", as: :analyze_topics
    post "sources/:source_video_id/topics/:topic_id/triage", to: "cuts#triage", as: :topic_triage

    # The cut composition: its ordered items and the render.
    get    "sources/:source_video_id/cut", to: "cuts#cut", as: :cut # live-progress frame
    post   "sources/:source_video_id/cut/items", to: "cuts#add_item", as: :cut_items
    delete "sources/:source_video_id/cut/items/:id", to: "cuts#remove_item", as: :cut_item
    post   "sources/:source_video_id/cut/items/:id/move", to: "cuts#move_item", as: :move_cut_item
    post   "sources/:source_video_id/cut/render", to: "cuts#render_cut", as: :render_cut

    # The export bundle: enqueue, poll its status, download the zip.
    get    "sources/:source_video_id/cut/export", to: "cuts#export_status", as: :cut_export
    post   "sources/:source_video_id/cut/export", to: "cuts#export_cut"
    get    "sources/:source_video_id/cut/export/download", to: "cuts#download_export", as: :download_cut_export

    # Opt-in AI packaging: titles, briefs, frame extraction/ranking, audience match.
    get    "sources/:source_video_id/cut/packaging", to: "cuts#packaging_status", as: :cut_packaging
    post   "sources/:source_video_id/cut/packaging", to: "cuts#package"
    get "niche",    to: "niche#show",     as: :niche
    get "niche/channels/:channel_id", to: "channels#show", as: :niche_channel
    get "niche/channels/:channel_id/videos/:video_id", to: "videos#show", as: :niche_channel_video
    get "settings", to: "settings#show",  as: :settings
  end
end
