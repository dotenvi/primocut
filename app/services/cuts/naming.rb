module Cuts
  # Filename helpers for a cut's clips and its export files. Pure string logic,
  # shared by the render (clip filenames) and the export step. Ported from the PoC
  # `render/encode.py::slugify`/`clip_filename`.
  module Naming
    module_function

    # ASCII, lowercase, hyphenated slug for a clip filename; never empty.
    def slugify(text, maxlen: 40)
      norm = (text || "").unicode_normalize(:nfkd)
                          .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
      s = norm.gsub(/[^a-zA-Z0-9]+/, "-").gsub(/\A-+|-+\z/, "").downcase
      s = s[0, maxlen].to_s.gsub(/\A-+|-+\z/, "")
      s.empty? ? "clip" : s
    end

    # `NNN-slug.mp4`, NNN = 1-based position in the composition, zero-padded to 3.
    def clip_filename(position, title)
      format("%03d-%s.mp4", position + 1, slugify(title))
    end
  end
end
