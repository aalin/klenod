# frozen_string_literal: true

require "pathname"

require_relative "errors"
require_relative "module_id"

module Klenod
  module Build
    RouteSegment = Data.define(:name, :kind, :param_name, :path_part) do
      def self.parse(name)
        case name
        when /\A\[\[\.\.\.(?<param_name>[A-Za-z_]\w*)\]\]\z/
          new(name, :optional_catch_all, $~[:param_name], nil)
        when /\A\[\.\.\.(?<param_name>[A-Za-z_]\w*)\]\z/
          new(name, :catch_all, $~[:param_name], "*#{$~[:param_name]}")
        when /\A\[(?<param_name>[A-Za-z_]\w*)\]\z/
          new(name, :dynamic, $~[:param_name], ":#{$~[:param_name]}")
        when /\A\((?<group_name>.+)\)\z/
          new(name, :group, nil, nil)
        when /\A@(?<slot_name>.+)\z/
          new(name, :parallel, $~[:slot_name], nil)
        else
          new(name, :static, nil, name)
        end
      end
    end

    RouteParam = Data.define(:name, :kind)
    PARAM_SEGMENT_KINDS = [:dynamic, :catch_all, :optional_catch_all].freeze

    PageRoute = Data.define(:path, :module_id, :segments, :layout_module_ids) do
      def params
        segments
          .select { |segment| segment.param_name && PARAM_SEGMENT_KINDS.include?(segment.kind) }
          .map { |segment| RouteParam.new(segment.param_name, segment.kind) }
      end
    end

    class PageDiscovery
      PAGE_EXTENSIONS = [".rb", ".haml"].freeze

      def initialize(source_dir:, pages_dir: "pages")
        @source_dir = Pathname.new(source_dir).expand_path
        @pages_dir = pages_dir
      end

      def call
        route_files
          .group_by { |path| route_path_for(route_segments_for(path)) }
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

        path = paths.fetch(0)
        PageRoute.new(
          route_path,
          ModuleId.new(relative_path_for(path), nil),
          route_segments_for(path),
          layout_module_ids_for(path)
        )
      end

      def route_segments_for(path)
        relative_dir = path.dirname.relative_path_from(source_dir.join(pages_dir)).to_s
        return [] if relative_dir == "."

        relative_dir.split("/").map { |name| RouteSegment.parse(name) }
      end

      def route_path_for(segments)
        path_parts = segments.filter_map(&:path_part)
        return "/" if path_parts.empty?

        "/#{path_parts.join("/")}"
      end

      def layout_module_ids_for(path)
        page_root = source_dir.join(pages_dir)
        relative_dir = path.dirname.relative_path_from(page_root).to_s
        dirs =
          if relative_dir == "."
            [page_root]
          else
            parts = relative_dir.split("/")
            [page_root] + parts.each_index.map { |index| page_root.join(*parts[0..index]) }
          end

        dirs.filter_map do |dir|
          layout_path = dir.join("layout.haml")
          ModuleId.new(relative_path_for(layout_path), nil) if layout_path.file?
        end
      end

      def relative_path_for(path)
        path.relative_path_from(source_dir).to_s
      end
    end
  end
end
