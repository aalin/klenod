# frozen_string_literal: true

require_relative "errors"
require_relative "module_id"
require_relative "dependency"

module Klenod
  module Build
    class Resolver
      DEFAULT_EXTENSIONS = [".rb", ".haml", ".css"].freeze

      def initialize(source_dir:, extensions: DEFAULT_EXTENSIONS)
        @source_dir = Pathname.new(source_dir).expand_path
        @extensions = extensions
      end

      attr_reader :source_dir

      def resolve(dependency)
        specifier, query = dependency.specifier.split("?", 2)
        base_path =
          if specifier.start_with?(".")
            importer_dir = dependency.importer_id&.dirname || "."
            @source_dir.join(importer_dir, specifier).cleanpath
          else
            @source_dir.join(specifier).cleanpath
          end

        assert_inside_source_dir!(base_path)
        resolved_path = resolve_existing_path(base_path)
        relative = resolved_path.relative_path_from(@source_dir).to_s

        ResolvedDependency.new(dependency, ModuleId.new(relative, query), {})
      end

      def absolute_path(module_id)
        path = @source_dir.join(module_id.path).cleanpath
        assert_inside_source_dir!(path)
        path
      end

      private

      def resolve_existing_path(path)
        return path if path.file?

        candidates =
          @extensions.filter_map do |extension|
            candidate = Pathname.new("#{path}#{extension}")
            candidate if candidate.file?
          end
        return candidates.fetch(0) if candidates.length == 1

        if candidates.length > 1
          relative = path.relative_path_from(@source_dir)
          matches = candidates.map { |candidate| candidate.relative_path_from(@source_dir) }.join(", ")
          raise ResolveError, "Ambiguous import #{relative}; matched #{matches}. Use an explicit extension."
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
