# frozen_string_literal: true

require "digest"
require "tsort"
require "async"

require_relative "../runtime/mod"
require_relative "../runtime/bundle"
require_relative "asset_generation_queue"
require_relative "errors"
require_relative "invalidation_result"
require_relative "module_id"
require_relative "module_record"
require_relative "resolver"
require_relative "transform_result"
require_relative "watched_pattern"

module Klenod
  module Build
    class Graph
      include TSort

      InFlightLoad = Struct.new(:task, :condition) do
        def self.create
          new(nil, Async::Condition.new)
        end

        def wait
          (task || condition.wait).wait
        end

        def start(task)
          self.task = task
          condition.signal(task)
        end
      end

      attr_reader :records, :mods, :asset_generation_queue, :mode
      attr_reader :plugins

      def initialize(source_dir:, plugins:, mode: :development, asset_generation_concurrency: AssetGenerationQueue::DEFAULT_CONCURRENCY)
        @resolver = Resolver.new(source_dir: source_dir, extensions: resolver_extensions(plugins))
        @plugins = plugins
        @mode = mode
        @asset_generation_queue = AssetGenerationQueue.new(concurrency: asset_generation_concurrency)
        @records = {}
        @mods = {}
        @virtual_sources = {}
        @virtual_owners = {}
        @loading_tasks = {}
      end

      def load(specifier)
        dependency = Dependency.create(specifier: specifier, importer_id: nil, kind: :entrypoint)
        resolved = resolve_dependency(dependency)
        load_module(resolved.module_id)
      end

      def bundle(entrypoints:)
        loaded_entrypoints =
          entrypoints.to_h do |entrypoint|
            [entrypoint, load(entrypoint).id.to_s]
          end
        load_all_runtime_dependencies

        Runtime::Bundle.new(
          loaded_entrypoints,
          runtime_module_specs,
          runtime_asset_specs,
          source_root: source_dir.to_s
        )
      end

      def assets
        @records.values.flat_map(&:assets).to_h { |asset| [asset.output_path, asset] }
      end

      def asset(output_path)
        assets.fetch(output_path)
      end

      def exports(record_or_module_id)
        module_id = module_id_for(record_or_module_id)
        @mods.fetch(module_id).const_get(:Exports)
      end

      def assets_for(logical_name)
        assets.values.select { |asset| asset.logical_name == logical_name.to_s }
      end

      def assets_for_module(record_or_module_id, type: nil, content_type: nil, recursive: true)
        module_ids_for_assets(record_or_module_id, recursive: recursive)
          .flat_map { |module_id| @records.fetch(module_id).assets }
          .select { |asset| asset_matches?(asset, type: type, content_type: content_type) }
      end

      def each_asset(&block)
        return enum_for(:each_asset) unless block

        assets.each_value(&block)
      end

      def wait_for_assets
        with_async_task do |task|
          each_asset.map { |asset| task.async { asset.wait } }.each(&:wait)
        end
      end

      def resolve_dependency(dependency)
        if (virtual_module_id = dependency.metadata[:virtual_module_id])
          return ResolvedDependency.new(dependency, virtual_module_id, {virtual: true})
        end

        @plugins.each do |plugin|
          resolved = plugin.resolve(dependency, self)
          return resolved if resolved
        end

        @resolver.resolve(dependency)
      end

      def absolute_path(module_id)
        @resolver.absolute_path(module_id)
      end

      def source_dir
        @resolver.source_dir
      end

      def register_virtual_module(module_id, source, owner_id: nil)
        @virtual_sources[module_id] = source
        @virtual_owners[module_id] = owner_id if owner_id
      end

      def unregister_virtual_modules(owner_id)
        module_ids = @virtual_owners.filter_map { |module_id, owner| module_id if owner == owner_id }
        module_ids.each do |module_id|
          @virtual_sources.delete(module_id)
          @virtual_owners.delete(module_id)
          @records.delete(module_id)
          @mods.delete(module_id)
        end
      end

      def invalidate_paths(changed_paths, removed_paths: [])
        previous_assets = assets
        changed_module_ids = module_ids_for_paths(changed_paths)
        removed_module_ids = module_ids_for_paths(removed_paths)
        pattern_owner_ids = module_ids_for_watched_paths(changed_paths + removed_paths)
        reload_module_ids = (changed_module_ids + pattern_owner_ids).uniq
        affected_dependents = dependent_closure(reload_module_ids + removed_module_ids)
        errors = []

        removed_module_ids.each do |module_id|
          @records.delete(module_id)
          @mods.delete(module_id)
        end

        reloaded_module_ids =
          reload_module_ids.filter_map do |module_id|
            load_module(module_id, force: true)
            module_id
          rescue => e
            errors << [module_id, e]
            nil
          end

        reevaluated_module_ids =
          affected_dependents.filter_map do |module_id|
            next if removed_module_ids.include?(module_id)
            next if reload_module_ids.include?(module_id)

            load_module(module_id, reevaluate: true)
            module_id
          rescue => e
            errors << [module_id, e]
            nil
          end
        asset_updates = diff_assets(previous_assets, assets)
        asset_changes = asset_changes_for(asset_updates)

        InvalidationResult.new(
          changed_module_ids.freeze,
          removed_module_ids.freeze,
          reloaded_module_ids.freeze,
          reevaluated_module_ids.freeze,
          asset_changes.added.freeze,
          asset_changes.changed.freeze,
          asset_changes.removed.freeze,
          asset_updates.freeze,
          errors.freeze
        )
      end

      def load_module(module_id, force: false, reevaluate: false)
        raise_import_cycle_if_present(module_id) unless force || reevaluate

        unless force || reevaluate
          return @loading_tasks.fetch(module_id).wait if @loading_tasks.key?(module_id)
        end

        task = current_async_task
        if task && !force && !reevaluate
          in_flight_load = InFlightLoad.create
          @loading_tasks[module_id] = in_flight_load
          loading_task = task.async { load_module_now(module_id, force: force, reevaluate: reevaluate) }
          in_flight_load.start(loading_task)
          begin
            return loading_task.wait
          ensure
            @loading_tasks.delete(module_id) if @loading_tasks[module_id].equal?(in_flight_load)
          end
        end

        load_module_now(module_id, force: force, reevaluate: reevaluate)
      end

      def load_module_now(module_id, force: false, reevaluate: false)
        with_loading_stack(module_id) do
          source = read_module_source(module_id)
          source_hash = Digest::SHA256.hexdigest(source)
          cached = @records[module_id]

          return cached if cached&.source_hash == source_hash && !force && !reevaluate

          transform = transform_module_source(module_id, source)
          resolved_dependencies = resolve_transform_dependencies(transform)
          dependency_records = load_eager_dependency_records(resolved_dependencies)
          transform = finalize_transform_result(module_id, transform, resolved_dependencies, dependency_records)
          assert_supported_transform!(module_id, source, transform)
          transformed_hash = Digest::SHA256.hexdigest(transform.code)
          mod = instantiate_module(module_id, transform, resolved_dependencies, dependency_records, cached)
          record = build_module_record(module_id, source, source_hash, transformed_hash, transform, resolved_dependencies, mod)

          @records[module_id] = record
          @mods[module_id] = mod
          record
        end
      end

      def tsort_each_node(&block)
        @records.each_key(&block)
      end

      def tsort_each_child(node, &block)
        record = @records.fetch(node)
        record.resolved_dependencies.map(&:module_id).each(&block)
      end

      def module_id_for(record_or_module_id)
        case record_or_module_id
        when ModuleRecord
          record_or_module_id.id
        when ModuleId
          record_or_module_id
        else
          ref = record_or_module_id.to_s
          @records.each_key.find { |module_id| module_id.to_s == ref } ||
            module_id_for_absolute_ref(ref) ||
            raise(KeyError, "No module loaded for #{record_or_module_id.inspect}")
        end
      end

      private

      def module_id_for_absolute_ref(ref)
        absolute_path = Pathname.new(ref).expand_path
        relative = absolute_path.relative_path_from(source_dir).to_s

        @records.each_key.find { |module_id| module_id.path == relative }
      rescue ArgumentError
        nil
      end

      def reachable_module_ids(record_or_module_id)
        root_id = module_id_for(record_or_module_id)
        seen = Set.new
        queue = [root_id]

        until queue.empty?
          module_id = queue.shift
          next if seen.include?(module_id)
          next unless @records.key?(module_id)

          seen << module_id
          queue.concat(@records.fetch(module_id).resolved_dependencies.map(&:module_id))
        end

        seen.to_a
      end

      def module_ids_for_assets(record_or_module_id, recursive:)
        return reachable_module_ids(record_or_module_id) if recursive

        [module_id_for(record_or_module_id)]
      end

      def asset_matches?(asset, type:, content_type:)
        return false if type && asset.metadata[:type] != type
        return false if content_type && asset.content_type != content_type

        true
      end

      def loading_stack
        Fiber[:klenod_loading_stack] || []
      end

      def raise_import_cycle_if_present(module_id)
        stack = loading_stack
        cycle_start = stack.index(module_id)
        return unless cycle_start

        raise ImportCycleError, stack[cycle_start..] + [module_id]
      end

      def with_loading_stack(module_id)
        previous_stack = loading_stack
        Fiber[:klenod_loading_stack] = previous_stack + [module_id]
        yield
      ensure
        Fiber[:klenod_loading_stack] = previous_stack
      end

      def read_module_source(module_id)
        load_source(module_id, @resolver.absolute_path(module_id))
      end

      def transform_module_source(module_id, source)
        transform(module_id, source)
      end

      def resolve_transform_dependencies(transform)
        transform.dependencies.map { |dependency| resolve_dependency(dependency) }
      end

      def load_eager_dependency_records(resolved_dependencies)
        load_dependency_records(eager_dependencies(resolved_dependencies))
      end

      def finalize_transform_result(module_id, transform, resolved_dependencies, dependency_records)
        finalize(module_id, transform, resolved_dependencies, dependency_records)
      end

      def assert_supported_transform!(module_id, source, transform)
        return if ruby_module_extension?(module_id.extname)
        return unless transform.code == source && transform.dependencies.empty? && transform.assets.empty?

        raise UnsupportedFileError, "No plugin transformed #{module_id.path.inspect}. Add a plugin for #{module_id.extname.inspect} files."
      end

      def ruby_module_extension?(extname)
        extname.empty? || extname == ".rb"
      end

      def instantiate_module(module_id, transform, resolved_dependencies, dependency_records, cached)
        Runtime::Mod.new(
          module_id.to_s,
          transform.code,
          imports: imports_for(resolved_dependencies, dependency_records),
          source_map: transform.source_map,
          version: cached ? cached.version + 1 : 0,
          eval_path: source_dir.join(module_id.path).to_s
        )
      end

      def imports_for(resolved_dependencies, dependency_records)
        resolved_dependencies.to_h do |resolved_dependency|
          value =
            if resolved_dependency.dependency.eager
              record = dependency_records.fetch(resolved_dependency.dependency.id)
              import_value(resolved_dependency, record)
            else
              Runtime::LazyImport.new do
                record = load_module(resolved_dependency.module_id)
                import_value(resolved_dependency, record)
              end
            end

          [resolved_dependency.dependency.id, value]
        end
      end

      def build_module_record(module_id, source, source_hash, transformed_hash, transform, resolved_dependencies, mod)
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
          transform.watched_patterns,
          mod.version,
          :loaded
        )
      end

      def module_ids_for_paths(paths)
        paths
          .map { |path| module_id_for_path(path) }
          .compact
          .select { |module_id| @records.key?(module_id) }
          .uniq
      end

      def module_ids_for_watched_paths(paths)
        relative_paths =
          paths.filter_map do |path|
            Pathname.new(path).expand_path.relative_path_from(@resolver.source_dir).to_s
          rescue ArgumentError
            nil
          end

        @records.filter_map do |module_id, record|
          module_id if relative_paths.any? { |path| record.watched_patterns.any? { |pattern| pattern.match?(path) } }
        end
      end

      def module_id_for_path(path)
        absolute_path = Pathname.new(path).expand_path
        relative = absolute_path.relative_path_from(@resolver.source_dir).to_s

        @records.each_key.find { |module_id| module_id.path == relative }
      rescue ArgumentError
        nil
      end

      def dependent_closure(module_ids)
        seen = Set.new
        queue = module_ids.dup

        until queue.empty?
          module_id = queue.shift

          direct_dependents(module_id).each do |dependent_id|
            next if seen.include?(dependent_id)

            seen << dependent_id
            queue << dependent_id
          end
        end

        seen.to_a
      end

      def direct_dependents(module_id)
        @records.filter_map do |candidate_id, record|
          candidate_id if record.resolved_dependencies.any? { |dependency| dependency.module_id == module_id }
        end
      end

      def load_dependency_records(resolved_dependencies)
        return {} if resolved_dependencies.empty?

        if resolved_dependencies.length == 1
          resolved_dependency = resolved_dependencies.fetch(0)
          return {
            resolved_dependency.dependency.id => load_module(resolved_dependency.module_id)
          }
        end

        with_async_task do |task|
          resolved_dependencies
            .map do |resolved_dependency|
              [
                resolved_dependency.dependency.id,
                task.async { load_module(resolved_dependency.module_id) }
              ]
            end
            .to_h { |dependency_id, child_task| [dependency_id, child_task.wait] }
        end
      end

      def eager_dependencies(resolved_dependencies)
        resolved_dependencies.select { |resolved_dependency| resolved_dependency.dependency.eager }
      end

      def load_all_runtime_dependencies
        queue = @records.values.flat_map(&:resolved_dependencies)

        until queue.empty?
          resolved_dependency = queue.shift
          next if @records.key?(resolved_dependency.module_id)

          record = load_module(resolved_dependency.module_id)
          queue.concat(record.resolved_dependencies)
        end
      end

      def with_async_task(&block)
        task = current_async_task

        return block.call(task) if task

        with_experimental_warnings_suppressed do
          Async(&block).wait
        end
      end

      def current_async_task
        Async::Task.current
      rescue RuntimeError
        nil
      end

      def with_experimental_warnings_suppressed
        enabled = Warning[:experimental]
        Warning[:experimental] = false
        yield
      ensure
        Warning[:experimental] = enabled
      end

      def runtime_module_specs
        @records.to_h do |module_id, record|
          imports =
            record.resolved_dependencies.to_h do |resolved_dependency|
              [
                resolved_dependency.dependency.id,
                runtime_import_spec(resolved_dependency, @records.fetch(resolved_dependency.module_id))
              ]
            end

          [
            module_id.to_s,
            Runtime::ModuleSpec.new(
              module_id.to_s,
              module_id.path,
              record.transformed_source,
              imports,
              record.source_map,
              record.version,
              Runtime::Mod.constant_name_for(module_id.to_s)
            )
          ]
        end
      end

      def runtime_asset_specs
        @records.values.flat_map(&:assets).to_h do |asset|
          [
            asset.output_path,
            Runtime::AssetSpec.new(
              asset.logical_name,
              asset.content_hash,
              asset.output_path,
              asset.content_type,
              asset.metadata
            )
          ]
        end
      end

      def diff_assets(previous_assets, current_assets)
        previous_paths = previous_assets.keys
        current_paths = current_assets.keys
        shared_paths = previous_paths & current_paths

        [
          *(current_paths - previous_paths).map do |path|
            AssetUpdate.new(path, nil, current_assets.fetch(path))
          end,
          *shared_paths.filter_map do |path|
            previous_asset = previous_assets.fetch(path)
            current_asset = current_assets.fetch(path)
            next if previous_asset.content_hash == current_asset.content_hash

            AssetUpdate.new(path, previous_asset, current_asset)
          end,
          *(previous_paths - current_paths).map do |path|
            AssetUpdate.new(path, previous_assets.fetch(path), nil)
          end
        ]
      end

      def asset_changes_for(asset_updates)
        AssetChanges.new(
          asset_updates.select(&:added?).map(&:output_path),
          asset_updates.select(&:changed?).map(&:output_path),
          asset_updates.select(&:removed?).map(&:output_path)
        )
      end

      def runtime_import_spec(resolved_dependency, record)
        value = plugin_runtime_import_value(resolved_dependency, record)

        Runtime::ImportSpec.new(record.id.to_s, value, resolved_dependency.dependency.eager)
      end

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
        return @virtual_sources.fetch(module_id) if @virtual_sources.key?(module_id)

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
            current.watched_patterns + result.watched_patterns,
            current.metadata.merge(result.metadata)
          )
        end
      end

      def finalize(module_id, result, resolved_dependencies, dependency_records)
        @plugins.reduce(result) do |current, plugin|
          plugin.finalize(module_id, current, resolved_dependencies, dependency_records, self)
        end
      end

      def import_value(resolved_dependency, record)
        value = plugin_import_value(resolved_dependency, record)
        return value unless value.nil?

        @mods.fetch(record.id).const_get(:Exports)
      end

      def plugin_import_value(resolved_dependency, record)
        @plugins.each do |plugin|
          value = plugin.import_value(resolved_dependency, record, self)
          return value unless value.nil?
        end

        nil
      end

      def plugin_runtime_import_value(resolved_dependency, record)
        @plugins.each do |plugin|
          value = plugin.runtime_import_value(resolved_dependency, record, self)
          return value unless value.nil?
        end

        nil
      end
    end
  end
end
