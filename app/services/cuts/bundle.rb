module Cuts
  # The finished export on disk. Missing until the bundle is actually built AND
  # the file is still there — a row that says `done` is not proof, since the zip
  # lives outside the database and can be cleared independently.
  class Bundle
    class NotReady < StandardError; end

    def call(cut:)
      export = cut.export
      raise NotReady, "That export is not ready." unless export&.state_done? && export.zip_rel_path.present?

      path = confined(export.zip_rel_path)
      raise NotReady, "The export bundle is no longer on disk." unless File.exist?(path)

      path
    end

    private

    # The bundle is addressed by a path this app's own export job wrote, never by
    # anything a request carries. It is still a path read out of a row and handed
    # to `send_file`, so it is proven to land inside the exports directory before
    # it is served: a row pointing anywhere else is treated as no bundle at all,
    # rather than as permission to read that file.
    def confined(rel_path)
      root = File.expand_path(Export.default_exports_dir)
      path = File.expand_path(File.join(root, rel_path))
      raise NotReady, "That export is not ready." unless path.start_with?(root + File::SEPARATOR)

      path
    end
  end
end
