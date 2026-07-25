module Adapters
  # The LLM seam for opt-in AI enrichment. A single `select` forces a deterministic
  # structured extraction and returns the parsed attributes Hash — the model fills a
  # JSON Schema, nothing more. Provider-agnostic via RubyLLM (Anthropic by default,
  # swappable by config), mirroring the PoC `analysis/llm.py::SelectionLLM`. The chat
  # factory is injectable so tests run with no network.
  #
  # Determinism: temperature 0 and a forced schema make the output a clean function
  # of the prompt, so the content-hash cache in [[Enrichment::VideoEnricher]] is
  # honest. `claude-opus-4-8` is newer than RubyLLM's bundled model registry, so
  # `assume_model_exists: true` skips its validation.
  class SelectionLlm
    class ExtractionError < StandardError; end

    DEFAULT_MODEL = "claude-opus-4-8".freeze

    def initialize(model: nil, provider: :anthropic, chat_factory: nil)
      @model = model || ENV["ENRICHMENT_MODEL"].presence || DEFAULT_MODEL
      @provider = provider
      @chat_factory = chat_factory
    end

    # Return the structured attributes the model recorded against `schema` (a JSON
    # Schema Hash). `model` overrides the configured model for this call only.
    def select(system:, user:, schema:, model: nil)
      content = build_chat(model || @model)
        .with_instructions(system)
        .with_temperature(0)
        .with_schema(schema)
        .ask(user)
        .content

      unless content.is_a?(Hash)
        raise ExtractionError, "the model did not return a structured object (got #{content.class})"
      end
      content
    end

    private

    def build_chat(model)
      return @chat_factory.call(model) if @chat_factory

      RubyLLM.chat(model:, provider: @provider, assume_model_exists: true)
    end
  end
end
