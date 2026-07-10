# frozen_string_literal: true

require "pathname"

require_relative "../dependency"
require_relative "../errors"
require_relative "../module_id"
require_relative "../plugin"
require_relative "../transform_result"
require_relative "../watched_pattern"

module Klenod
  module Build
    module Plugins
      class RouterPlugin < Plugin
        RouteSegment = Data.define(:name, :kind, :param_name, :path_part) do
          def self.parse(name)
            case name
            when /\A\[\[\.\.\.(?<param_name>[A-Za-z_]\w*)\]\]\z/
              new(name, :optional_catch_all, $~[:param_name], nil)
            when /\A\[\.\.\.(?<param_name>[A-Za-z_]\w*)\]\z/
              new(name, :catch_all, $~[:param_name], "*#{$~[:param_name]}")
            when /\A\[(?<param_name>[A-Za-z_]\w*)\]\z/
              new(name, :dynamic, $~[:param_name], ":#{$~[:param_name]}")
            when /\A\(\.\)(?<path_part>.+)\z/
              new(name, :intercept_current, nil, $~[:path_part])
            when /\A\(\.\.\)(?<path_part>.+)\z/
              new(name, :intercept_parent, nil, $~[:path_part])
            when /\A\(\.\.\.\)(?<path_part>.+)\z/
              new(name, :intercept_root, nil, $~[:path_part])
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

        RouteManifest = Data.define(:routes) do
          def entrypoints
            routes.map { |route| route.module_id.to_s }
          end

          def [](path)
            routes_by_path.fetch(path)
          end

          def fetch(path, *fallback, &block)
            routes_by_path.fetch(path, *fallback, &block)
          end

          def each_route(&block)
            return enum_for(:each_route) unless block

            routes.each(&block)
          end

          private

          def routes_by_path
            routes.to_h { |route| [route.path, route] }
          end
        end

        def initialize(specifier: "virtual:router", pages_dir: "pages", extensions: [".rb", ".haml"])
          @specifier = specifier
          @pages_dir = pages_dir
          @extensions = extensions
          @module_id = ModuleId.new("#{specifier}.rb", nil)
        end

        attr_reader :specifier, :pages_dir, :extensions

        def resolve(dependency, _context)
          return nil unless dependency.specifier == specifier

          ResolvedDependency.new(dependency, @module_id, {virtual: true})
        end

        def load(module_id, context)
          return nil unless module_id == @module_id

          generate_router_source(discover(source_dir: context.source_dir), mode: context.mode)
        end

        def transform(module_id, code, _context)
          return TransformResult.identity(code) unless module_id == @module_id

          TransformResult.new(
            code,
            [],
            nil,
            [],
            watched_patterns(module_id),
            {}
          )
        end

        def discover(source_dir:)
          RouteManifest.new(routes(source_dir: Pathname.new(source_dir).expand_path))
        end

        private

        def routes(source_dir:)
          route_files(source_dir)
            .group_by { |path| route_key_for(route_segments_for(source_dir, path)) }
            .map { |_route_key, paths| route_for(source_dir, paths) }
            .sort_by(&:path)
        end

        def route_files(source_dir)
          root = source_dir.join(pages_dir)
          return [] unless root.directory?

          extensions.flat_map { |extension| root.glob("**/page#{extension}") }.select(&:file?)
        end

        def watched_patterns(module_id)
          extensions.flat_map do |extension|
            [
              WatchedPattern.new(module_id, "#{pages_dir}/**/page#{extension}", :router_page, {}),
              WatchedPattern.new(module_id, "#{pages_dir}/**/layout#{extension}", :router_layout, {})
            ]
          end
        end

        def route_for(source_dir, paths)
          route_path = route_path_for(route_segments_for(source_dir, paths.fetch(0)))
          if paths.length > 1
            matches = paths.map { |path| relative_path_for(source_dir, path) }.sort.join(", ")
            raise ResolveError, "Ambiguous page route #{route_path}; matched #{matches}. Use only one page file per route."
          end

          path = paths.fetch(0)
          PageRoute.new(
            route_path,
            ModuleId.new(relative_path_for(source_dir, path), nil),
            route_segments_for(source_dir, path),
            layout_module_ids_for(source_dir, path)
          )
        end

        def route_segments_for(source_dir, path)
          relative_dir = path.dirname.relative_path_from(source_dir.join(pages_dir)).to_s
          return [] if relative_dir == "."

          relative_dir.split("/").map { |name| RouteSegment.parse(name) }
        end

        def route_path_for(segments)
          path_parts = route_path_parts_for(segments)

          return "/" if path_parts.empty?
          "/#{path_parts.join("/")}"
        end

        def route_path_parts_for(segments)
          segments.each_with_object([]) do |segment, path_parts|
            case segment.kind
            when :intercept_current
              path_parts << segment.path_part
            when :intercept_parent
              path_parts.pop
              path_parts << segment.path_part
            when :intercept_root
              path_parts.clear
              path_parts << segment.path_part
            else
              path_parts << segment.path_part if segment.path_part
            end
          end
        end

        def route_key_for(segments)
          segments.map { |segment| [segment.kind, segment.path_part, segment.param_name] }
        end

        def layout_module_ids_for(source_dir, path)
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
            layout_path = layout_path_for(dir)
            ModuleId.new(relative_path_for(source_dir, layout_path), nil) if layout_path
          end
        end

        def layout_path_for(dir)
          matches = extensions.filter_map do |extension|
            path = dir.join("layout#{extension}")
            path if path.file?
          end
          return nil if matches.empty?
          return matches.fetch(0) if matches.length <= 1

          relative = matches.map(&:to_s).sort.join(", ")
          raise ResolveError, "Ambiguous layout route; matched #{relative}. Use only one layout file per directory."
        end

        def relative_path_for(source_dir, path)
          path.relative_path_from(source_dir).to_s
        end

        def generate_router_source(manifest, mode:)
          imports = import_refs(manifest, mode: mode)
          <<~RUBY
            Segment = Data.define(:name, :kind, :param_name, :path_part)
            Param = Data.define(:name, :kind)
            #{import_definitions(imports, mode: mode)}

            module Default
              Route = Data.define(:path, :module_id, :segments, :match_parts, :layout_module_ids, :page_ref, :layout_refs) do
                def params
                  segments
                    .select { |segment| segment.param_name && [:dynamic, :catch_all, :optional_catch_all].include?(segment.kind) }
                    .map { |segment| Param.new(segment.param_name, segment.kind) }
                end

                def page
                  Default.resolve_import(page_ref)
                end

                def layouts
                  layout_refs.map { |layout_ref| Default.resolve_import(layout_ref) }
                end
              end

              class RouteNode
                attr_reader :segment, :path, :children, :slots
                attr_accessor :route

                def initialize(segment:, path:, route: nil)
                  @segment = segment
                  @path = path
                  @route = route
                  @children = []
                  @slots = {}
                end

                def root?
                  segment.nil?
                end

                def leaf?
                  !route.nil?
                end

                def child_for(segment)
                  children.find { |child| Default.same_segment?(child.segment, segment) }
                end

                def add_child(segment, path)
                  child_for(segment) || children.tap { _1 << RouteNode.new(segment: segment, path: path) }.last
                end

                def add_slot(segment, path)
                  slots[segment.param_name.to_sym] ||= add_child(segment, path)
                end
              end

              Match = Data.define(:route, :params) do
                def page
                  route.page
                end

                def layouts
                  route.layouts
                end
              end

              ROUTES = [
            #{route_entries(matching_routes(manifest), imports: imports).join(",\n")}
              ].freeze

              def self.routes
                ROUTES
              end

              def self.tree
                TREE
              end

              def self.match(path)
                parts = normalize_path(path)
                route = ROUTES.find { |candidate| route_matches?(candidate, parts) }
                return nil unless route

                Match.new(route, params_for(route, parts))
              end

              def self.resolve_import(value)
                value.respond_to?(:call) && value.class.name == "Klenod::Runtime::LazyImport" ? value.call : value
              end

              def self.normalize_path(path)
                normalized = path.to_s.split("?", 2).first
                normalized = "/\#{normalized}" unless normalized.start_with?("/")
                normalized.split("/").reject(&:empty?)
              end

              def self.build_tree(routes)
                root = RouteNode.new(segment: nil, path: "/")

                routes.each do |route|
                  cursor = root
                  path_parts = []

                  route.segments.each do |segment|
                    update_path_parts(path_parts, segment)
                    path = path_parts.empty? ? "/" : "/\#{path_parts.join("/")}"
                    cursor = segment.kind == :parallel ? cursor.add_slot(segment, path) : cursor.add_child(segment, path)
                  end

                  cursor.route = route
                end

                root
              end

              def self.update_path_parts(path_parts, segment)
                case segment.kind
                when :intercept_current
                  path_parts << segment.path_part
                when :intercept_parent
                  path_parts.pop
                  path_parts << segment.path_part
                when :intercept_root
                  path_parts.clear
                  path_parts << segment.path_part
                else
                  path_parts << segment.path_part if segment.path_part
                end
              end

              def self.same_segment?(left, right)
                left&.name == right&.name &&
                  left&.kind == right&.kind &&
                  left&.param_name == right&.param_name &&
                  left&.path_part == right&.path_part
              end

              def self.route_matches?(route, parts)
                cursor = 0
                route.match_parts.each do |match_part|
                  case match_part[0]
                  when :static
                    return false unless parts[cursor] == match_part[1]
                    cursor += 1
                  when :dynamic
                    return false unless parts[cursor]
                    cursor += 1
                  when :catch_all
                    return false if parts[cursor..].empty?
                    cursor = parts.length
                  when :optional_catch_all
                    cursor = parts.length
                  end
                end
                cursor == parts.length
              end

              def self.params_for(route, parts)
                cursor = 0
                params = {}
                route.match_parts.each do |match_part|
                  case match_part[0]
                  when :static
                    cursor += 1
                  when :dynamic
                    params[match_part[2].to_sym] = parts[cursor]
                    cursor += 1
                  when :catch_all
                    params[match_part[2].to_sym] = parts[cursor..]
                    cursor = parts.length
                  when :optional_catch_all
                    params[match_part[2].to_sym] = parts[cursor..]
                    cursor = parts.length
                  end
                end
                params
              end

              TREE = build_tree(ROUTES)
            end
          RUBY
        end

        def route_entries(routes, imports:)
          routes.map do |route|
            layouts = route.layout_module_ids.map { |module_id| imports.fetch(module_id.to_s) }
            [
              "    Route.new(",
              "      #{route.path.inspect},",
              "      #{route.module_id.to_s.inspect},",
              "      #{segments_source(route.segments)},",
              "      #{match_parts_source(route.segments)},",
              "      #{route.layout_module_ids.map(&:to_s).inspect},",
              "      #{imports.fetch(route.module_id.to_s)},",
              "      #{layouts_source(layouts)}",
              "    )"
            ].join("\n")
          end
        end

        def matching_routes(manifest)
          manifest.routes.sort_by { |route| route_priority(route) }
        end

        def route_priority(route)
          [
            route_score(route),
            -visible_segments(route).length,
            route.path
          ]
        end

        def route_score(route)
          visible_segments(route).sum { |segment| segment_score(segment) }
        end

        def visible_segments(route)
          route.segments.reject { |segment| [:group, :parallel].include?(segment.kind) }
        end

        def segment_score(segment)
          case segment.kind
          when :static, :intercept_current, :intercept_parent, :intercept_root
            0
          when :dynamic
            10
          when :catch_all
            100
          when :optional_catch_all
            1_000
          else
            0
          end
        end

        def import_refs(manifest, mode:)
          specifiers =
            manifest.routes.flat_map do |route|
              [route.module_id.to_s, *route.layout_module_ids.map(&:to_s)]
            end.uniq

          specifiers.each_with_index.to_h do |specifier, index|
            [specifier, "ROUTER_IMPORT_#{index}"]
          end
        end

        def import_definitions(imports, mode:)
          imports
            .map { |specifier, const_name| "#{const_name} = #{import_statement(specifier, mode: mode)}" }
            .join("\n")
        end

        def segments_source(segments)
          "[#{segments.map { |segment| segment_source(segment) }.join(", ")}]"
        end

        def match_parts_source(segments)
          route_match_parts_for(segments).inspect
        end

        def segment_source(segment)
          "Segment.new(#{segment.name.inspect}, #{segment.kind.inspect}, #{segment.param_name.inspect}, #{segment.path_part.inspect})"
        end

        def route_match_parts_for(segments)
          route_segments_for_matching(segments).filter_map do |segment|
            case segment.kind
            when :static, :intercept_current, :intercept_parent, :intercept_root
              [:static, segment.path_part, nil]
            when :dynamic, :catch_all, :optional_catch_all
              [segment.kind, segment.path_part, segment.param_name]
            end
          end
        end

        def route_segments_for_matching(segments)
          segments.each_with_object([]) do |segment, match_segments|
            case segment.kind
            when :group, :parallel
              next
            when :intercept_current
              match_segments << segment
            when :intercept_parent
              match_segments.pop
              match_segments << segment
            when :intercept_root
              match_segments.clear
              match_segments << segment
            else
              match_segments << segment if segment.path_part || [:dynamic, :catch_all, :optional_catch_all].include?(segment.kind)
            end
          end
        end

        def layouts_source(layouts)
          "[#{layouts.join(", ")}]"
        end

        def import_statement(specifier, mode:)
          if mode != :development
            "import(#{specifier.inspect})"
          else
            "lazy_import(#{specifier.inspect})"
          end
        end
      end
    end
  end
end
