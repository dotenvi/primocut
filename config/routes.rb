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
    get "niche",    to: "niche#show",     as: :niche
    get "niche/channels/:channel_id", to: "channels#show", as: :niche_channel
    get "niche/channels/:channel_id/videos/:video_id", to: "videos#show", as: :niche_channel_video
    get "settings", to: "settings#show",  as: :settings
  end
end
