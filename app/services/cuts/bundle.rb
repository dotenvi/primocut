module Cuts
  # The finished export on disk. Missing until the bundle is actually built AND
  # the file is still there — a row that says `done` is not proof, since the zip
  # lives outside the database and can be cleared independently.
  class Bundle
    class NotReady < StandardError; end

    def call(cut:)
      export = cut.export
      raise NotReady, "That export is not ready." unless export&.state_done? && export.zip_rel_path.present?

      path = File.join(Export.default_exports_dir, export.zip_rel_path)
      raise NotReady, "The export bundle is no longer on disk." unless File.exist?(path)

      path
    end
  end
end
