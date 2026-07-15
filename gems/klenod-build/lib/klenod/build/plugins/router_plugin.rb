# frozen_string_literal: true

require_relative "../dependency"
require_relative "../errors"
require_relative "../module_id"
require_relative "../plugin"
require "klenod/runtime/source_map"
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

        PageRoute = Data.define(:path, :page_module_id, :handler_module_id, :segments, :layout_module_ids, :slot_layout_module_id) do
          def params
            segments
              .select { |segment| segment.param_name && PARAM_SEGMENT_KINDS.include?(segment.kind) }
              .map { |segment| RouteParam.new(segment.param_name, segment.kind) }
          end

          def module_id
            page_module_id || handler_module_id
          end

          def kind
            return :page_and_handler if page_module_id && handler_module_id
            return :page if page_module_id

            :handler
          end
        end

        SpecialView = Data.define(:kind, :path, :view_module_id, :segments, :layout_module_ids, :status) do
          def module_id
            view_module_id
          end
        end

        RouteManifest = Data.define(:routes, :special_views) do
          def entrypoints
            [
              *routes.flat_map { |route| [route.page_module_id, route.handler_module_id] },
              *special_views.map(&:view_module_id)
            ].compact.map(&:to_s)
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

        def initialize(specifier: "virtual:router", pages_dir: "pages", extensions: [".rb", ".haml"], route_base_class: nil)
          @specifier = specifier
          @pages_dir = pages_dir
          @extensions = extensions
          @route_base_class = route_base_class
          @module_id = ModuleId.new("#{specifier}.rb", nil)
        end

        attr_reader :specifier, :pages_dir, :extensions, :route_base_class

        def resolve(dependency, _context)
          return nil unless dependency.specifier == specifier

          ResolvedDependency.new(dependency, @module_id, {virtual: true})
        end

        def load(module_id, context)
          return nil unless module_id.scheme == :virtual && module_id == @module_id

          generate_router_source(discover(source_dir: context.source_dir))
        end

        def transform(module_id, code, context)
          if module_id.scheme == :virtual && module_id == @module_id
            return TransformResult.new(
              code,
              [],
              nil,
              [],
              watched_patterns(module_id),
              {}
            )
          end

          return TransformResult.identity(code) unless route_handler_module_id?(module_id, context)

          wrapped = route_handler_source(code)
          TransformResult.new(
            wrapped,
            [],
            Klenod::Runtime::SourceMap::SourceMap.parse(code, wrapped),
            [],
            [],
            {router_route_handler: true}
          )
        end

        def import_value(_resolved_dependency, record, context)
          return nil unless record.metadata[:router_route_handler]

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        def runtime_import_value(_resolved_dependency, record, _context)
          return nil unless record.metadata[:router_route_handler]

          Runtime::DefaultImport.new(:Default)
        end

        def discover(source_dir:)
          root = Pathname.new(source_dir).expand_path
          RouteManifest.new(routes(source_dir: root), special_views(source_dir: root))
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

          [
            *extensions.flat_map { |extension| root.glob("**/page#{extension}") },
            *root.glob("**/route.rb")
          ].select(&:file?)
        end

        def special_views(source_dir:)
          special_view_files(source_dir)
            .group_by { |path| [special_view_kind_for(path), route_key_for(route_segments_for(source_dir, path))] }
            .map { |(_kind, _route_key), paths| special_view_for(source_dir, paths) }
            .sort_by { |view| [view.kind.to_s, view.path] }
        end

        def special_view_files(source_dir)
          root = source_dir.join(pages_dir)
          return [] unless root.directory?

          extensions.flat_map do |extension|
            [
              *root.glob("**/not-found#{extension}"),
              *root.glob("**/error#{extension}")
            ]
          end.select(&:file?).reject { |path| route_segments_for(source_dir, path).any? { |segment| segment.kind == :parallel } }
        end

        def special_view_for(source_dir, paths)
          path = paths.fetch(0)
          kind = special_view_kind_for(path)
          if paths.length > 1
            matches = paths.map { |match| relative_path_for(source_dir, match) }.sort.join(", ")
            raise ResolveError, "Ambiguous #{kind.to_s.tr("_", "-")} route #{route_path_for(route_segments_for(source_dir, path))}; matched #{matches}. Use only one special view file per directory."
          end

          segments = route_segments_for(source_dir, path)
          SpecialView.new(
            kind,
            route_path_for(segments),
            ModuleId.new(relative_path_for(source_dir, path), nil),
            segments,
            layout_module_ids_for(source_dir, path),
            (kind == :not_found) ? 404 : 500
          )
        end

        def special_view_kind_for(path)
          name = path.basename(path.extname).to_s
          return :not_found if name == "not-found"
          return :error if name == "error"

          raise ResolveError, "Unsupported special view #{path}"
        end

        def watched_patterns(module_id)
          patterns = extensions.flat_map do |extension|
            [
              WatchedPattern.new(module_id, "#{pages_dir}/**/page#{extension}", :router_page, {}),
              WatchedPattern.new(module_id, "#{pages_dir}/**/layout#{extension}", :router_layout, {}),
              WatchedPattern.new(module_id, "#{pages_dir}/**/not-found#{extension}", :router_not_found, {}),
              WatchedPattern.new(module_id, "#{pages_dir}/**/error#{extension}", :router_error, {})
            ]
          end
          patterns + [WatchedPattern.new(module_id, "#{pages_dir}/**/route.rb", :router_route, {})]
        end

        def route_for(source_dir, paths)
          segments = route_segments_for(source_dir, paths.fetch(0))
          route_path = route_path_for(segments)
          page_paths = paths.reject { |path| route_handler_path?(path) }
          handler_path = paths.find { |path| route_handler_path?(path) }
          if page_paths.length > 1
            matches = page_paths.map { |path| relative_path_for(source_dir, path) }.sort.join(", ")
            raise ResolveError, "Ambiguous route #{route_path}; matched #{matches}. Use only one page file per directory."
          end

          path = page_paths.fetch(0, handler_path)
          PageRoute.new(
            route_path,
            page_paths.fetch(0, nil)&.then { |page_path| ModuleId.new(relative_path_for(source_dir, page_path), nil) },
            handler_path&.then { |route_path| ModuleId.new(relative_path_for(source_dir, route_path), nil) },
            segments,
            page_paths.empty? ? [] : layout_module_ids_for(source_dir, path),
            page_paths.empty? ? nil : slot_layout_module_id_for(source_dir, path, segments)
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

        def slot_layout_module_id_for(source_dir, path, segments)
          parallel_index = segments.index { |segment| segment.kind == :parallel }
          return nil unless parallel_index

          page_root = source_dir.join(pages_dir)
          relative_dir = path.dirname.relative_path_from(page_root).to_s
          owner_parts = (relative_dir == ".") ? [] : relative_dir.split("/").first(parallel_index)
          owner_dir = owner_parts.empty? ? page_root : page_root.join(*owner_parts)
          layout_path = layout_path_for(owner_dir)

          ModuleId.new(relative_path_for(source_dir, layout_path), nil) if layout_path
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

        def generate_router_source(manifest)
          imports = import_refs(manifest)
          <<~RUBY
            Segment = Data.define(:name, :kind, :param_name, :path_part)
            Param = Data.define(:name, :kind)
            #{import_definitions(imports)}

            module Default
              Route = Data.define(:path, :page_module_id, :handler_module_id, :segments, :match_parts, :layout_module_ids, :slot_layout_module_id, :page_ref, :handler_ref, :layout_refs) do
                def params
                  segments
                    .select { |segment| segment.param_name && [:dynamic, :catch_all, :optional_catch_all].include?(segment.kind) }
                    .map { |segment| Param.new(segment.param_name, segment.kind) }
                end

                def module_id
                  page_module_id || handler_module_id
                end

                def kind
                  return :page_and_handler if page_module_id && handler_module_id
                  return :page if page_module_id

                  :handler
                end

                def page
                  return nil unless page_ref

                  Default.resolve_import(page_ref)
                end

                def handler
                  return nil unless handler_ref

                  Default.resolve_import(handler_ref)
                end

                def layouts
                  layout_refs.map { |layout_ref| Default.resolve_import(layout_ref) }
                end
              end

              SpecialView = Data.define(:kind, :path, :status, :module_id, :segments, :match_parts, :layout_module_ids, :page_ref, :layout_refs) do
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

              SlotMatch = Data.define(:route, :params, :layout_module_id) do
                def page
                  route.page
                end

                def layouts
                  route.layouts
                end
              end

              Match = Data.define(:route, :params, :slots) do
                def page
                  route.page
                end

                def handler
                  route.handler
                end

                def layouts
                  route.layouts
                end
              end

              SpecialMatch = Data.define(:route, :params) do
                def page
                  route.page
                end

                def layouts
                  route.layouts
                end

                def slots
                  {}
                end

                def status
                  route.status
                end
              end

              ROUTES = [
            #{route_entries(matching_routes(manifest), imports: imports).join(",\n")}
              ].freeze
              NOT_FOUND_VIEWS = [
            #{special_view_entries(special_views_for(manifest, :not_found), imports: imports).join(",\n")}
              ].freeze
              ERROR_VIEWS = [
            #{special_view_entries(special_views_for(manifest, :error), imports: imports).join(",\n")}
              ].freeze

              def self.routes
                ROUTES
              end

              def self.not_found_views
                NOT_FOUND_VIEWS
              end

              def self.error_views
                ERROR_VIEWS
              end

              def self.tree
                TREE
              end

              def self.match(path)
                parts = normalize_path(path)
                route = main_route_for(parts)
                return nil unless route

                Match.new(route, params_for(route, parts), slot_matches_for(route, parts))
              end

              def self.not_found(path)
                special_match(NOT_FOUND_VIEWS, path)
              end

              def self.error(path)
                special_match(ERROR_VIEWS, path)
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

              def self.route_prefix_matches?(route, parts)
                cursor = 0
                route.match_parts.each do |match_part|
                  case match_part[0]
                  when :static
                    return false unless parts[cursor] == match_part[1]
                    cursor += 1
                  when :dynamic
                    return false unless parts[cursor]
                    cursor += 1
                  when :catch_all, :optional_catch_all
                    cursor = parts.length
                  end
                end
                true
              end

              def self.special_match(views, path)
                parts = normalize_path(path)
                view = special_view_for(views, parts)
                return nil unless view

                SpecialMatch.new(view, params_for(view, parts))
              end

              def self.special_view_for(views, parts)
                views
                  .select { |view| special_view_matches?(view, parts) }
                  .max_by { |view| [fallback_depth(view), -route_score_for(view)] }
              end

              def self.special_view_matches?(view, parts)
                cursor = 0
                view.match_parts.each do |match_part|
                  case match_part[0]
                  when :static
                    return false unless parts[cursor] == match_part[1]
                    cursor += 1
                  when :dynamic
                    return false unless parts[cursor]
                    cursor += 1
                  when :catch_all, :optional_catch_all
                    cursor = parts.length
                  end
                end
                cursor <= parts.length
              end

              def self.fallback_depth(view)
                view.match_parts.count { |match_part| [:static, :dynamic, :catch_all, :optional_catch_all].include?(match_part[0]) }
              end

              def self.route_score_for(route)
                route.match_parts.sum do |match_part|
                  case match_part[0]
                  when :static
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
              end

              def self.main_route_for(parts)
                MAIN_ROUTES.find { |candidate| route_matches?(candidate, parts) }
              end

              def self.slot_matches_for(main_route, parts)
                SLOT_ROUTES.each_with_object({}) do |route, slots|
                  next unless route_matches?(route, parts)
                  next unless route_prefix_matches?(main_route, normalize_path(route.path))

                  slots[slot_name_for(route)] = SlotMatch.new(route, params_for(route, parts), route.slot_layout_module_id)
                end
              end

              def self.parallel_route?(route)
                route.segments.any? { |segment| segment.kind == :parallel }
              end

              def self.slot_name_for(route)
                route.segments.find { |segment| segment.kind == :parallel }.param_name.to_sym
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

              MAIN_ROUTES = ROUTES.reject { |route| parallel_route?(route) }.freeze
              SLOT_ROUTES = ROUTES.select { |route| parallel_route?(route) }.freeze
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
              "      #{route.page_module_id&.to_s.inspect},",
              "      #{route.handler_module_id&.to_s.inspect},",
              "      #{segments_source(route.segments)},",
              "      #{match_parts_source(route.segments)},",
              "      #{route.layout_module_ids.map(&:to_s).inspect},",
              "      #{route.slot_layout_module_id&.to_s.inspect},",
              "      #{route.page_module_id ? imports.fetch(route.page_module_id.to_s) : "nil"},",
              "      #{route.handler_module_id ? imports.fetch(route.handler_module_id.to_s) : "nil"},",
              "      #{layouts_source(layouts)}",
              "    )"
            ].join("\n")
          end
        end

        def special_view_entries(views, imports:)
          views.map do |view|
            layouts = view.layout_module_ids.map { |module_id| imports.fetch(module_id.to_s) }
            [
              "    SpecialView.new(",
              "      #{view.kind.inspect},",
              "      #{view.path.inspect},",
              "      #{view.status.inspect},",
              "      #{view.view_module_id.to_s.inspect},",
              "      #{segments_source(view.segments)},",
              "      #{match_parts_source(view.segments)},",
              "      #{view.layout_module_ids.map(&:to_s).inspect},",
              "      #{imports.fetch(view.view_module_id.to_s)},",
              "      #{layouts_source(layouts)}",
              "    )"
            ].join("\n")
          end
        end

        def special_views_for(manifest, kind)
          manifest.special_views.select { |view| view.kind == kind }
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

        def import_refs(manifest)
          specifiers =
            [
              *manifest.routes.flat_map do |route|
                [
                  route.page_module_id&.to_s,
                  route.handler_module_id&.to_s,
                  *route.layout_module_ids.map(&:to_s)
                ]
              end,
              *manifest.special_views.flat_map do |view|
                [
                  view.view_module_id.to_s,
                  *view.layout_module_ids.map(&:to_s)
                ]
              end
            ].uniq
          specifiers.compact!

          specifiers.each_with_index.to_h do |specifier, index|
            [specifier, "ROUTER_IMPORT_#{index}"]
          end
        end

        def import_definitions(imports)
          imports
            .map { |specifier, const_name| "#{const_name} = lazy_import(#{specifier.inspect})" }
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

        def route_handler_module_id?(module_id, context)
          return false unless module_id.path.start_with?("#{pages_dir}/")
          return false unless module_id.path.end_with?("/route.rb")

          route_handler_module_ids(context.source_dir).include?(module_id)
        end

        def route_handler_module_ids(source_dir)
          discover(source_dir: source_dir).routes.filter_map(&:handler_module_id)
        end

        def route_handler_path?(path)
          path.basename.to_s == "route.rb"
        end

        def route_handler_source(source)
          superclass = route_base_class ? " < #{route_base_class}" : ""
          <<~RUBY
            # frozen_string_literal: true
            KlenodImport = method(:__klenod_import__)
            class Route#{superclass}
              def self.__klenod_import__(dependency_id)
                KlenodImport.call(dependency_id)
              end

              def __klenod_import__(dependency_id)
                self.class.__klenod_import__(dependency_id)
              end

            #{marked_route_handler_body(source)}
            end
            Default = Route
          RUBY
        end

        def marked_route_handler_body(source)
          source.each_line.with_index(1).map do |line, line_no|
            if ruby_magic_comment?(line)
              ""
            elsif line.strip.empty?
              line
            else
              "  # #{Klenod::Runtime::SourceMap::Mark.new(line_no, line.chomp)}\n  #{line}"
            end
          end.join
        end

        def ruby_magic_comment?(line)
          line.match?(/\A#\s*(?:frozen_string_literal|encoding):/)
        end
      end
    end
  end
end
