# frozen_string_literal: true

require_relative "errors"
require_relative "module_id"
require_relative "dependency"

module Klenod
  module Build
    class Resolver
      DEFAULT_EXTENSIONS = [".rb", ".haml"].freeze

      def initialize(source_dir:, extensions: DEFAULT_EXTENSIONS)
        @source_dir = Pathname.new(source_dir).expand_path
        @extensions = extensions
        @resolved_module_ids = {}
        @absolute_paths = {}
      end

      attr_reader :source_dir

      def resolve(dependency)
        specifier, query = dependency.specifier.split("?", 2)
        base_path =
          if specifier.start_with?("/")
            @source_dir.join(specifier.delete_prefix("/")).cleanpath
          elsif specifier.start_with?(".")
            importer_dir = dependency.importer_id&.dirname || "."
            @source_dir.join(importer_dir, specifier).cleanpath
          else
            @source_dir.join(specifier).cleanpath
          end

        assert_inside_source_dir!(base_path)
        module_id =
          @resolved_module_ids.fetch([base_path.to_s, query]) do |key|
            resolved_path = resolve_existing_path(base_path)
            relative = resolved_path.relative_path_from(@source_dir).to_s
            @resolved_module_ids[key] = ModuleId.new(relative, query)
          end

        ResolvedDependency.new(dependency, module_id, {})
      end

      def absolute_path(module_id)
        @absolute_paths.fetch(module_id.path) do |path_key|
          path = @source_dir.join(path_key).cleanpath
          assert_inside_source_dir!(path)
          @absolute_paths[path_key] = path
        end
      end

      def clear_cache
        @resolved_module_ids.clear
        @absolute_paths.clear
      end

      private

      def resolve_existing_path(path)
        return path if path.file?

        @extensions.each do |extension|
          candidate = Pathname.new("#{path}#{extension}")
          return candidate if candidate.file?
        end

        raise ResolveError, "Could not resolve #{path.relative_path_from(@source_dir)}"
      end

      def assert_inside_source_dir!(path)
        expanded = path.expand_path.to_s
        source = @source_dir.to_s
        return if expanded == source || expanded.start_with?("#{source}/")

        raise ResolveError, "Resolved path escapes source_dir: #{path}"
      end
    end
  end
end
