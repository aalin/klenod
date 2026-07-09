# frozen_string_literal: true

require "pathname"

require_relative "errors"
require_relative "module_id"

module Klenod
  module Build
    PageRoute = Data.define(:path, :module_id)

    class PageDiscovery
      PAGE_EXTENSIONS = [".rb", ".haml"].freeze

      def initialize(source_dir:, pages_dir: "pages")
        @source_dir = Pathname.new(source_dir).expand_path
        @pages_dir = pages_dir
      end

      def call
        route_files
          .group_by { |path| route_path_for(path) }
          .map { |route_path, paths| route_for(route_path, paths) }
          .sort_by(&:path)
      end

      private

      attr_reader :source_dir, :pages_dir

      def route_files
        root = source_dir.join(pages_dir)
        return [] unless root.directory?

        root.glob("**/page{.rb,.haml}").select(&:file?)
      end

      def route_for(route_path, paths)
        if paths.length > 1
          matches = paths.map { |path| relative_path_for(path) }.sort.join(", ")
          raise ResolveError, "Ambiguous page route #{route_path}; matched #{matches}. Use only one page file per route."
        end

        PageRoute.new(route_path, ModuleId.new(relative_path_for(paths.fetch(0)), nil))
      end

      def route_path_for(path)
        relative_dir =
          path
            .dirname
            .relative_path_from(source_dir.join(pages_dir))
            .to_s
        return "/" if relative_dir == "."

        "/#{relative_dir}"
      end

      def relative_path_for(path)
        path.relative_path_from(source_dir).to_s
      end
    end
  end
end
