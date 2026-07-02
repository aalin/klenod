# frozen_string_literal: true

module Klenod
  module Runtime
    ModuleSpec =
      Data.define(:id, :source, :imports, :source_map, :version, :constant_name)

    ImportSpec = Data.define(:target_id, :value)

    AssetSpec =
      Data.define(:logical_name, :content_hash, :output_path, :content_type, :bytes, :metadata)

    class Bundle
      attr_reader :entrypoints, :modules, :assets

      def self.load_file(path)
        Marshal.load(File.binread(path))
      end

      def initialize(entrypoints, modules, assets)
        @entrypoints = entrypoints
        @modules = modules
        @assets = assets
        @mods = {}
      end

      def load(entrypoint = nil)
        id =
          if entrypoint
            entrypoint
          elsif entrypoints.respond_to?(:values)
            entrypoints.values.first
          else
            entrypoints.first
          end

        id = id.to_s
        id = entrypoints.fetch(id, id) if entrypoints.respond_to?(:fetch)

        instantiate(id)
      end

      def mod(id)
        @mods.fetch(id.to_s)
      end

      def marshal_dump
        [@entrypoints, @modules, @assets]
      end

      def marshal_load(data)
        @entrypoints, @modules, @assets = data
        @mods = {}
      end

      private

      def instantiate(id)
        id = id.to_s
        return @mods.fetch(id) if @mods.key?(id)

        spec = @modules.fetch(id)
        imports =
          spec.imports.to_h do |dependency_id, target_id|
            import_spec =
              if target_id.is_a?(ImportSpec)
                target_id
              else
                ImportSpec.new(target_id, nil)
              end

            value = import_spec.value || instantiate(import_spec.target_id).const_get(:Exports)
            [dependency_id, value]
          end

        @mods[id] =
          Mod.new(
            spec.id,
            spec.source,
            imports: imports,
            source_map: spec.source_map,
            version: spec.version,
            constant_name: spec.constant_name
          )
      end
    end
  end
end
