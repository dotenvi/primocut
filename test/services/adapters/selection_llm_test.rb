require "test_helper"

# Tests for the LLM extraction seam with the chat fully faked (no network, no
# RubyLLM call). Confirms the deterministic wiring (temperature 0 + forced schema)
# and that a non-object response is rejected.
class Adapters::SelectionLlmTest < ActiveSupport::TestCase
  FakeMessage = Struct.new(:content)

  # Records the fluent chat calls and returns a canned message from `ask`.
  class FakeChat
    attr_reader :calls

    def initialize(content)
      @content = content
      @calls = {}
    end

    def with_instructions(system) = tap { @calls[:system] = system }
    def with_temperature(t) = tap { @calls[:temperature] = t }
    def with_schema(schema) = tap { @calls[:schema] = schema }

    def ask(user, with: nil)
      @calls[:user] = user
      @calls[:with_bytes] = with ? File.binread(with) : nil # read the temp file before it is unlinked
      FakeMessage.new(@content)
    end
  end

  test "forces a deterministic structured extraction and returns the hash" do
    fake = FakeChat.new({ "tone" => "hype" })
    llm = Adapters::SelectionLlm.new(chat_factory: ->(_model) { fake })

    out = llm.select(system: "sys prompt", user: "Video title: X", schema: { "type" => "object" })

    assert_equal({ "tone" => "hype" }, out)
    assert_equal 0, fake.calls[:temperature]         # deterministic
    assert_equal "sys prompt", fake.calls[:system]
    assert_equal "Video title: X", fake.calls[:user]
    assert_equal({ "type" => "object" }, fake.calls[:schema])
  end

  test "raises when the model does not return a structured object" do
    llm = Adapters::SelectionLlm.new(chat_factory: ->(_model) { FakeChat.new("not a hash") })

    assert_raises(Adapters::SelectionLlm::ExtractionError) do
      llm.select(system: "s", user: "u", schema: {})
    end
  end

  test "attaches raw image bytes for a vision extraction" do
    fake = FakeChat.new({ "face_count" => 1 })
    llm = Adapters::SelectionLlm.new(chat_factory: ->(_model) { fake })
    bytes = "\xFF\xD8\xFF and the rest of a jpeg".b

    out = llm.select(system: "s", user: "Analyse this thumbnail.", schema: {}, image: bytes)

    assert_equal({ "face_count" => 1 }, out)
    assert_equal bytes, fake.calls[:with_bytes] # bytes reached the chat via a temp file
  end

  test "the per-call model override reaches the chat factory" do
    seen = nil
    llm = Adapters::SelectionLlm.new(chat_factory: ->(model) { seen = model; FakeChat.new({}) })
    llm.select(system: "s", user: "u", schema: {}, model: "claude-haiku-4-5")
    assert_equal "claude-haiku-4-5", seen
  end
end
