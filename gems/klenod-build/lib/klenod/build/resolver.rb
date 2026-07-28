# frozen_string_literal: true

require_relative "errors"
require_relative "module_id"
require_relative "dependency"

module Klenod
  module Build
    class Resolver
      DEFAULT_EXTENSIONS = [".rb", ".haml"].freeze

      def initialize(source_dir:, extensions: DEFAULT_EXTENSIONS, profiler: nil)
        @source_dir_path = File.expand_path(source_dir)
        @source_dir = Pathname.new(@source_dir_path)
        @extensions = extensions
        @profiler = profiler
        @resolved_module_ids = {}
        @absolute_paths = {}
      end

      attr_reader :source_dir

      def resolve(dependency)
        specifier, query = dependency.specifier.split("?", 2)
        base_path =
          if specifier.start_with?("/")
            File.expand_path(specifier.delete_prefix("/"), @source_dir_path)
          elsif specifier.start_with?(".")
            importer_dir = dependency.importer_id&.dirname || "."
            File.expand_path(File.join(importer_dir, specifier), @source_dir_path)
          else
            File.expand_path(specifier, @source_dir_path)
          end

        assert_inside_source_dir!(base_path)
        key = [base_path, query]
        module_id = @resolved_module_ids[key]
        if module_id
          @profiler&.count(:resolver_cache_hit)
        else
          @profiler&.count(:resolver_cache_miss)
          resolved_path = resolve_existing_path(base_path)
          relative = relative_source_path(resolved_path)
          module_id = @resolved_module_ids[key] = ModuleId.new(relative, query)
        end

        ResolvedDependency.new(dependency, module_id, {})
      end

      def absolute_path(module_id)
        path = @absolute_paths[module_id.path]
        if path
          @profiler&.count(:resolver_absolute_path_cache_hit)
          return path
        end

        @profiler&.count(:resolver_absolute_path_cache_miss)
        @absolute_paths.fetch(module_id.path) do |path_key|
          path = Pathname.new(File.expand_path(path_key, @source_dir_path))
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
        return path if File.file?(path)

        @extensions.each do |extension|
          candidate = "#{path}#{extension}"
          return candidate if File.file?(candidate)
        end

        relative = relative_source_path(path)
        raise ResolveError.new("Could not resolve #{relative}", unresolved_path: relative)
      end

      def assert_inside_source_dir!(path)
        expanded = File.expand_path(path.to_s)
        return if expanded == @source_dir_path || expanded.start_with?("#{@source_dir_path}/")

        raise ResolveError, "Resolved path escapes source_dir: #{path}"
      end

      def relative_source_path(path)
        Pathname.new(path).relative_path_from(@source_dir).to_s
      end
    end
  end
end
