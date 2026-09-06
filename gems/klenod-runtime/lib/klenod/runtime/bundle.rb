# frozen_string_literal: true

require_relative "asset_url"

module Klenod
  module Runtime
    ModuleSpec =
      Data.define(:id, :source_path, :source, :imports, :source_map, :version, :constant_name)

    ImportSpec = Data.define(:target_id, :value, :eager)
    DefaultImport = Data.define(:name)

    AssetSpec =
      Data.define(:logical_name, :content_hash, :output_path, :content_type, :metadata, :url) do
        def initialize(logical_name = nil, content_hash = nil, output_path = nil, content_type = nil, metadata = nil, url = nil, **keywords)
          logical_name = keywords.fetch(:logical_name, logical_name)
          content_hash = keywords.fetch(:content_hash, content_hash)
          output_path = keywords.fetch(:output_path, output_path)
          content_type = keywords.fetch(:content_type, content_type)
          metadata = keywords.fetch(:metadata, metadata)
          url = keywords.fetch(:url, url)
          url ||= output_path
          super(logical_name:, content_hash:, output_path:, content_type:, metadata:, url:)
        end
      end
    AssetReference = Data.define(:index, :asset)

    class Bundle
      attr_reader :entrypoints, :modules, :assets, :source_root, :base, :asset_origin

      def self.load(source, source_root: nil)
        BundleFormat.load(source, source_root: source_root)
      end

      def self.load_file(path, source_root: nil)
        load(path, source_root: source_root)
      end

      def initialize(entrypoints, modules, assets, source_root: nil, base: AssetUrl::DEFAULT_BASE)
        @entrypoints = entrypoints
        @modules = modules
        @source_root = source_root
        @base = AssetUrl.normalize(base)
        @asset_origin = AssetUrl.origin(@base)
        @assets = bind_asset_urls(assets)
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

      def load_entrypoints
        entrypoint_ids = entrypoints.respond_to?(:values) ? entrypoints.values : entrypoints
        entrypoint_ids.map { |entrypoint| load(entrypoint) }
      end

      def preload(module_ref = nil)
        module_ids =
          if module_ref
            reachable_module_ids(module_ref)
          else
            @modules.keys
          end

        module_ids.map { |module_id| instantiate(module_id) }
      end

      def preload_entrypoints
        entrypoint_ids = entrypoints.respond_to?(:values) ? entrypoints.values : entrypoints
        seen = Set.new
        module_ids =
          entrypoint_ids
            .flat_map { |entrypoint| reachable_module_ids(entrypoint) }
            .select { |module_id| seen.add?(module_id) }
        module_ids.map { |module_id| instantiate(module_id) }
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

      def asset_url(asset_or_output_path)
        if asset_or_output_path.respond_to?(:output_path)
          asset = @assets.fetch(asset_or_output_path.output_path, asset_or_output_path)
          return asset.url || AssetUrl.join(base, asset.output_path)
        end

        @assets.fetch(asset_or_output_path).url
      rescue KeyError
        AssetUrl.join(base, asset_or_output_path)
      end

      def assets_for(logical_name)
        @assets.values.select { |asset| asset.logical_name == logical_name.to_s }
      end

      def assets_for_module(module_ref, type: nil, content_type: nil, recursive: true)
        asset_references_for_module(module_ref, type: type, content_type: content_type, recursive: recursive)
          .map(&:asset)
      end

      def asset_references_for_module(module_ref, type: nil, content_type: nil, recursive: true)
        seen_assets = {}
        module_ids_for_assets(module_ref, recursive: recursive)
          .each_with_index
          .flat_map do |module_id, index|
            assets_for_runtime_module(module_id).filter_map do |asset|
              next unless asset_matches?(asset, type: type, content_type: content_type)
              next if seen_assets.key?(asset.output_path)

              seen_assets[asset.output_path] = true
              AssetReference.new(index:, asset:)
            end
          end
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
        [@entrypoints, @modules, @assets, @source_root, @base]
      end

      def marshal_load(data)
        @entrypoints, @modules, assets, @source_root, base = data
        @base = AssetUrl.normalize(base)
        @asset_origin = AssetUrl.origin(@base)
        @assets = bind_asset_urls(assets)
        @mods = {}
      end

      def module_id_for(module_ref)
        id = module_ref.respond_to?(:path) ? module_ref.path : module_ref.to_s
        id = entrypoints.fetch(id, id) if entrypoints.respond_to?(:fetch)
        return id if @modules.key?(id)
        canonical_module_id = module_id_for_canonical_ref(id)
        return canonical_module_id if canonical_module_id

        if (relative_id = module_id_for_absolute_ref(id))
          return relative_id
        end

        raise KeyError, "No module in bundle for #{module_ref.inspect}"
      end

      private

      def bind_asset_urls(assets)
        assets.to_h do |output_path, asset|
          legacy_url = asset.url.nil? || (asset.url == asset.output_path && base != AssetUrl::DEFAULT_BASE)
          url = legacy_output_path?(asset.output_path) ? AssetUrl.legacy_join(base, asset.output_path) : AssetUrl.join(base, asset.output_path)
          [output_path, legacy_url ? asset.with(url:) : asset]
        end
      end

      def legacy_output_path?(output_path)
        output_path.start_with?(AssetUrl::LEGACY_OUTPUT_PREFIX)
      end

      def assets_for_runtime_module(module_id)
        module_spec = @modules.fetch(module_id)
        logical_names = [module_spec.id, module_spec.source_path].uniq
        @assets.values.select { |asset| logical_names.include?(asset.logical_name) }
      end

      SCHEME_PATTERN = /\A[A-Za-z][A-Za-z0-9+.-]*:/

      def module_id_for_canonical_ref(id)
        canonical =
          if id.match?(SCHEME_PATTERN)
            canonical_scheme_ref(id)
          elsif !id.start_with?("/")
            "app:/#{id.delete_prefix("/")}"
          end

        canonical if canonical && @modules.key?(canonical)
      end

      def canonical_scheme_ref(id)
        scheme, rest = id.split(":", 2)
        return id if rest.start_with?("/", "//")

        "#{scheme}:/#{rest}"
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
        root_id = module_id_for(module_ref)
        seen = Set.new
        ordered = []
        queue = [root_id]
        index = 0

        while index < queue.length
          module_id = queue[index]
          index += 1
          next unless seen.add?(module_id)
          next unless @modules.key?(module_id)

          ordered << module_id
          queue.concat(
            @modules
              .fetch(module_id)
              .imports
              .values
              .map { |import_spec| import_spec.is_a?(ImportSpec) ? import_spec.target_id : import_spec }
          )
        end

        ordered
      end

      def module_ids_for_assets(module_ref, recursive:)
        return Array(module_ref).map { |ref| module_id_for(ref) }.uniq unless recursive

        seen = []
        Array(module_ref).flat_map do |ref|
          ordered_module_ids_for_assets(module_id_for(ref), seen)
        end
      end

      def ordered_module_ids_for_assets(module_id, seen)
        return [] if seen.include?(module_id)
        return [] unless @modules.key?(module_id)

        seen << module_id
        dependency_ids =
          @modules
            .fetch(module_id)
            .imports
            .values
            .map { |import_spec| import_spec.is_a?(ImportSpec) ? import_spec.target_id : import_spec }

        if File.extname(module_id) == ".css"
          dependency_ids.flat_map { |dependency_id| ordered_module_ids_for_assets(dependency_id, seen) } + [module_id]
        else
          [module_id] + dependency_ids.flat_map { |dependency_id| ordered_module_ids_for_assets(dependency_id, seen) }
        end
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

require_relative "bundle_format"
