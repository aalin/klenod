# frozen_string_literal: true

module Klenod
  module Build
    WatchedPattern = Data.define(:importer_id, :glob, :kind, :metadata) do
      def match?(path)
        File.fnmatch?(glob, path, File::FNM_PATHNAME)
      end
    end
  end
end
