require "test_helper"

class Cuts::NamingTest < ActiveSupport::TestCase
  Naming = Cuts::Naming

  test "slugify is ascii, lowercase, hyphenated and never empty" do
    assert_equal "cafe-com-acao", Naming.slugify("Café com Ação")
    assert_equal "hello-world", Naming.slugify("  Hello, World!  ")
    assert_equal "clip", Naming.slugify("")
    assert_equal "clip", Naming.slugify("!!!")
    assert_equal "clip", Naming.slugify(nil)
  end

  test "slugify truncates to maxlen without a trailing hyphen" do
    slug = Naming.slugify("a" * 100)
    assert_equal 40, slug.length
    assert_equal "word", Naming.slugify("word-------extra", maxlen: 4)
  end

  test "clip_filename is a 1-based zero-padded NNN-slug.mp4" do
    assert_equal "001-opening.mp4", Naming.clip_filename(0, "Opening")
    assert_equal "012-cafe.mp4", Naming.clip_filename(11, "Café")
  end
end
