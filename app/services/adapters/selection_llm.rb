require "tempfile"

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
    # Schema Hash). `image` attaches raw image bytes for a vision extraction (the
    # thumbnail kind); `model` overrides the configured model for this call only.
    def select(system:, user:, schema:, image: nil, images: nil, model: nil)
      chat = build_chat(model || @model)
        .with_instructions(system)
        .with_temperature(0)
        .with_schema(schema)

      attachments = images || (image ? [ image ] : [])
      content = ask(chat, user, attachments).content

      unless content.is_a?(Hash)
        raise ExtractionError, "the model did not return a structured object (got #{content.class})"
      end
      content
    end

    private

    # RubyLLM attaches images from paths/URLs/IO — raw bytes travel through
    # short-lived temp files whose extension carries the format (sniffed from the
    # magic bytes) so the provider tags the base64 correctly. `attachments` is a
    # list of raw image byte strings (empty for a text-only extraction; one for the
    # thumbnail kind; several for the frame-ranking vision pass).
    def ask(chat, user, attachments)
      return chat.ask(user) if attachments.empty?

      files = attachments.each_with_index.map do |bytes, i|
        file = Tempfile.new([ "img-#{i}", image_extension(bytes) ], binmode: true)
        file.write(bytes)
        file.flush
        file
      end
      chat.ask(user, with: files.map(&:path))
    ensure
      Array(files).each { |f| f.close!  }
    end

    MAGIC = {
      "\xFF\xD8\xFF".b => ".jpg",
      "\x89PNG\r\n\x1A\n".b => ".png",
      "GIF8".b => ".gif"
    }.freeze

    def image_extension(bytes)
      data = bytes.b
      MAGIC.each { |magic, ext| return ext if data.start_with?(magic) }
      return ".webp" if data[0, 4] == "RIFF".b && data[8, 4] == "WEBP".b

      ".jpg" # YouTube's default; a wrong guess is the provider's error to raise
    end

    def build_chat(model)
      return @chat_factory.call(model) if @chat_factory

      RubyLLM.chat(model:, provider: @provider, assume_model_exists: true)
    end
  end
end
