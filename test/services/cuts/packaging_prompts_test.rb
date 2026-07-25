require "test_helper"

class Cuts::PackagingPromptsTest < ActiveSupport::TestCase
  PP = Cuts::PackagingPrompts

  def context
    {
      niche: { project_name: "Niche", channels: 2, outliers: 3, format: "long" },
      differential: [ { attribute: "has_face", source: "thumbnail_llm", freq_outlier: 0.8, freq_control: 0.3, lift: 2.6, verdict: "strong" } ],
      conventions: [ { attribute: "clickbait", source: "title_llm", freq: 0.9, n: 20 } ],
      carries_value: { "person_names" => [ { value: "Ana", videos_outlier: 3, videos_control: 1, lift: 3.0 } ] },
      examples: [ { video_id: "vid1", title: "Real", median_multiple: 3.0, title_attrs: { "person_names" => [ "Ana" ] } } ],
      flat: false
    }
  end

  test "pattern_index assigns stable D/C/V ids across the three lenses" do
    ids = PP.pattern_index(context)
    assert_equal "differential", ids["D1"][:kind]
    assert_equal "convention", ids["C1"][:kind]
    assert_equal "carries_value", ids["V1"][:kind]
    assert_equal "person_names", ids["V1"][:field]
  end

  test "the titles prompt renders the niche, clip, patterns and examples" do
    ids = PP.pattern_index(context)
    prompt = PP.build_titles_prompt({ title: "Opening", summary: "", transcript_excerpt: "" }, context, 5, ids)
    assert_includes prompt, "[D1] has_face"
    assert_includes prompt, "80% of outliers vs 30%"
    assert_includes prompt, "[vid1]"
    assert_includes prompt, "Propose exactly 5 titles"
  end
end
