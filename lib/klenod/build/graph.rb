# frozen_string_literal: true

require "digest"
require "tsort"

require_relative "../runtime/mod"
require_relative "../runtime/bundle"
require_relative "module_id"
require_relative "module_record"
require_relative "resolver"
require_relative "transform_result"

module Klenod
  module Build
    class Graph
      include TSort

      attr_reader :records, :mods

      def initialize(source_dir:, plugins:)
        @resolver = Resolver.new(source_dir: source_dir, extensions: resolver_extensions(plugins))
        @plugins = plugins
        @records = {}
        @mods = {}
      end

      def load(specifier)
        dependency = Dependency.create(specifier: specifier, importer_id: nil, kind: :entrypoint)
        resolved = resolve_dependency(dependency)
        load_module(resolved.module_id)
      end

      def bundle(entrypoints:)
        loaded_entrypoints = entrypoints.map { |entrypoint| load(entrypoint).id }
        Runtime::Bundle.new(loaded_entrypoints, @records, [])
      end

      def resolve_dependency(dependency)
        @plugins.each do |plugin|
          resolved = plugin.resolve(dependency, self)
          return resolved if resolved
        end

        @resolver.resolve(dependency)
      end

      def absolute_path(module_id)
        @resolver.absolute_path(module_id)
      end

      def load_module(module_id)
        absolute_path = @resolver.absolute_path(module_id)
        source = load_source(module_id, absolute_path)
        source_hash = Digest::SHA256.hexdigest(source)
        cached = @records[module_id]

        return cached if cached&.source_hash == source_hash

        transform = transform(module_id, source)
        transformed_hash = Digest::SHA256.hexdigest(transform.code)
        resolved_dependencies = transform.dependencies.map { |dependency| resolve_dependency(dependency) }

        dependency_records = resolved_dependencies.to_h do |resolved_dependency|
          [resolved_dependency.dependency.id, load_module(resolved_dependency.module_id)]
        end

        imports =
          resolved_dependencies.to_h do |resolved_dependency|
            record = dependency_records.fetch(resolved_dependency.dependency.id)
            [resolved_dependency.dependency.id, import_value(resolved_dependency, record)]
          end

        mod =
          Runtime::Mod.new(
            module_id.to_s,
            transform.code,
            imports: imports,
            source_map: transform.source_map,
            version: cached ? cached.version + 1 : 0
          )

        record =
          ModuleRecord.new(
            module_id,
            source_hash,
            transformed_hash,
            transform.dependencies,
            resolved_dependencies,
            source,
            transform.code,
            transform.source_map,
            transform.assets,
            mod.version,
            :loaded
          )

        @records[module_id] = record
        @mods[module_id] = mod
        record
      end

      def tsort_each_node(&block)
        @records.each_key(&block)
      end

      def tsort_each_child(node, &block)
        record = @records.fetch(node)
        record.resolved_dependencies.map(&:module_id).each(&block)
      end

      private

      def resolver_extensions(plugins)
        image_extensions =
          plugins.flat_map do |plugin|
            plugin.class.const_defined?(:EXTENSIONS, false) ? plugin.class.const_get(:EXTENSIONS) : []
          end

        (Resolver::DEFAULT_EXTENSIONS + image_extensions).uniq
      end

      def load_source(module_id, absolute_path)
        @plugins.each do |plugin|
          loaded = plugin.load(module_id, self)
          return loaded if loaded
        end

        absolute_path.binread
      end

      def transform(module_id, source)
        @plugins.reduce(TransformResult.identity(source)) do |current, plugin|
          result = plugin.transform(module_id, current.code, self) || TransformResult.identity(current.code)
          TransformResult.new(
            result.code,
            current.dependencies + result.dependencies,
            result.source_map || current.source_map,
            current.assets + result.assets,
            current.metadata.merge(result.metadata)
          )
        end
      end

      def import_value(resolved_dependency, record)
        @plugins.each do |plugin|
          value = plugin.import_value(resolved_dependency, record, self)
          return value unless value.nil?
        end

        @mods.fetch(record.id).const_get(:Exports)
      end
    end
  end
end
