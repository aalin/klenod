# frozen_string_literal: true

module Klenod
  module Runtime
    ModuleSpec =
      Data.define(:id, :source_path, :source, :imports, :source_map, :version, :constant_name)

    ImportSpec = Data.define(:target_id, :value, :eager)
    DefaultImport = Data.define(:name)

    AssetSpec =
      Data.define(:logical_name, :content_hash, :output_path, :content_type, :metadata)

    class Bundle
      attr_reader :entrypoints, :modules, :assets, :source_root

      def self.load_file(path, source_root: nil)
        bundle = Marshal.load(File.binread(path))
        bundle.source_root = source_root if source_root
        bundle
      end

      def initialize(entrypoints, modules, assets, source_root: nil)
        @entrypoints = entrypoints
        @modules = modules
        @assets = assets
        @source_root = source_root
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

      def exports(entrypoint = nil)
        load(entrypoint).const_get(:Exports)
      end

      def mod(id)
        @mods.fetch(id.to_s)
      end

      def asset(output_path)
        @assets.fetch(output_path)
      end

      def assets_for(logical_name)
        @assets.values.select { |asset| asset.logical_name == logical_name.to_s }
      end

      def assets_for_module(module_ref, type: nil, content_type: nil, recursive: true)
        module_ids_for_assets(module_ref, recursive: recursive)
          .flat_map { |module_id| assets_for(module_id) }
          .select { |asset| asset_matches?(asset, type: type, content_type: content_type) }
      end

      def each_asset(&block)
        return enum_for(:each_asset) unless block

        @assets.each_value(&block)
      end

      def source_root=(source_root)
        @source_root = source_root&.to_s
        @mods = {}
      end

      def marshal_dump
        [@entrypoints, @modules, @assets, @source_root]
      end

      def marshal_load(data)
        @entrypoints, @modules, @assets, @source_root = data
        @mods = {}
      end

      private

      def module_id_for_ref(module_ref)
        id = module_ref.respond_to?(:path) ? module_ref.path : module_ref.to_s
        return id if @modules.key?(id)

        if (relative_id = module_id_for_absolute_ref(id))
          return relative_id
        end

        raise KeyError, "No module in bundle for #{module_ref.inspect}"
      end

      def module_id_for_absolute_ref(id)
        return nil unless source_root

        root = File.expand_path(source_root)
        path = File.expand_path(id)
        return nil unless path.start_with?("#{root}/")

        relative = path.delete_prefix("#{root}/")
        relative if @modules.key?(relative)
      end

      def reachable_module_ids(module_ref)
        root_id = module_id_for_ref(module_ref)
        seen = []
        queue = [root_id]

        until queue.empty?
          module_id = queue.shift
          next if seen.include?(module_id)
          next unless @modules.key?(module_id)

          seen << module_id
          queue.concat(
            @modules
              .fetch(module_id)
              .imports
              .values
              .map { |import_spec| import_spec.is_a?(ImportSpec) ? import_spec.target_id : import_spec }
          )
        end

        seen
      end

      def module_ids_for_assets(module_ref, recursive:)
        return reachable_module_ids(module_ref) if recursive

        [module_id_for_ref(module_ref)]
      end

      def asset_matches?(asset, type:, content_type:)
        return false if type && asset.metadata[:type] != type
        return false if content_type && asset.content_type != content_type

        true
      end

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
                ImportSpec.new(target_id, nil, true)
              end

            value =
              if import_spec.eager
                resolve_import_value(import_spec)
              else
                LazyImport.new { resolve_import_value(import_spec) }
              end
            [dependency_id, value]
          end

        @mods[id] =
          Mod.new(
            spec.id,
            spec.source,
            imports: imports,
            source_map: spec.source_map,
            version: spec.version,
            constant_name: spec.constant_name,
            eval_path: eval_path_for(spec)
          )
      end

      def eval_path_for(spec)
        return spec.source_path unless source_root

        File.join(source_root, spec.source_path)
      end

      def resolve_import_value(import_spec)
        exports = instantiate(import_spec.target_id).const_get(:Exports)

        case import_spec.value
        when DefaultImport
          exports.const_get(import_spec.value.name)
        else
          import_spec.value || exports
        end
      end
    end
  end
end
