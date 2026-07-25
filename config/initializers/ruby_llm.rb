# RubyLLM is the provider-agnostic seam for the opt-in AI enrichment (Phase 3).
# The provider/model is chosen per call by [[Adapters::SelectionLlm]]; the key is
# read from ENV without a project prefix (see .env / dotenv-rails). A missing key
# is fine at boot — it only surfaces when an enrichment actually runs.
RubyLLM.configure do |config|
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.request_timeout = 120
  # We use the plain `RubyLLM.chat` API, not the ActiveRecord `acts_as` integration;
  # opting into the new API silences the legacy deprecation warning on boot.
  config.use_new_acts_as = true
end
