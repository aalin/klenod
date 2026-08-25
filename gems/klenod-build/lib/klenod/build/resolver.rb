# frozen_string_literal: true

require_relative "errors"
require_relative "filesystem_resolver"
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
        @filesystem_resolver = FilesystemResolver.new(root: @source_dir, extensions: @extensions)
        @resolved_module_ids = {}
        @absolute_paths = {}
      end

      attr_reader :source_dir

      def resolve(dependency)
        module_id = resolve_app_module_id(dependency)
        raise ResolveError, "Unknown import scheme #{module_id.scheme.inspect} for #{dependency.specifier.inspect}" unless module_id.scheme == :app

        base_path = File.expand_path(module_id.relative_path, @source_dir_path)
        assert_inside_source_dir!(base_path)
        key = [base_path, module_id.query]
        resolved_module_id = @resolved_module_ids[key]
        if resolved_module_id
          @profiler&.count(:resolver_cache_hit)
        else
          @profiler&.count(:resolver_cache_miss)
          resolved_path = @filesystem_resolver.resolve(module_id.relative_path)
          relative = relative_source_path(resolved_path)
          resolved_module_id = @resolved_module_ids[key] = ModuleId.new("app:/#{relative}", module_id.query)
        end

        ResolvedDependency.new(dependency, resolved_module_id, {})
      end

      def absolute_path(module_id)
        path = @absolute_paths[module_id.to_s]
        if path
          @profiler&.count(:resolver_absolute_path_cache_hit)
          return path
        end

        @profiler&.count(:resolver_absolute_path_cache_miss)
        @absolute_paths.fetch(module_id.to_s) do |path_key|
          raise ResolveError, "Cannot map non-app module to source_dir: #{module_id}" unless module_id.scheme == :app

          path = Pathname.new(File.expand_path(module_id.relative_path, @source_dir_path))
          assert_inside_source_dir!(path)
          @absolute_paths[path_key] = path
        end
      end

      def clear_cache
        @resolved_module_ids.clear
        @absolute_paths.clear
      end

      private

      def resolve_app_module_id(dependency)
        specifier = dependency.specifier.to_s
        return ModuleId.parse(specifier) if specifier.match?(ModuleId::SCHEME_PATTERN)

        importer_id = dependency.importer_id
        if importer_id
          importer_id.merge(specifier)
        else
          ModuleId.new("app:/#{specifier.delete_prefix("/")}")
        end
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
