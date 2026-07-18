# frozen_string_literal: true

require "tsort"
require "async"

require "klenod/runtime/mod"
require "klenod/runtime/bundle"
require_relative "asset_generation_queue"
require_relative "errors"
require_relative "hashing"
require_relative "invalidation_result"
require_relative "load_result"
require_relative "module_id"
require_relative "module_record"
require_relative "profiler"
require_relative "resolver"
require_relative "transform_result"
require_relative "watched_pattern"

module Klenod
  module Build
    class Graph
      include TSort

      AsyncResult = Data.define(:value, :error) do
        def self.capture
          new(yield, nil)
        rescue => e
          new(nil, e)
        end

        def self.unwrap(value)
          return value unless value.is_a?(self)

          raise value.error if value.error

          value.value
        end
      end

      FailedModule = Data.define(:error)

      InFlightLoad = Struct.new(:result, :condition) do
        def self.create
          new(nil, Async::Condition.new)
        end

        def wait
          AsyncResult.unwrap(result || condition.wait)
        end

        def finish(result)
          self.result = result
          condition.signal(result)
        end
      end

      attr_reader :records, :mods, :asset_generation_queue, :mode, :profiler
      attr_reader :plugins

      def initialize(
        source_dir:,
        plugins:,
        mode: :development,
        asset_generation_concurrency: AssetGenerationQueue::DEFAULT_CONCURRENCY,
        asset_download_concurrency: AssetGenerationQueue::DEFAULT_DOWNLOAD_CONCURRENCY,
        profiler: nil
      )
        @resolver = Resolver.new(source_dir: source_dir)
        @plugins = plugins
        @mode = mode
        @asset_generation_queue =
          AssetGenerationQueue.new(
            concurrency: asset_generation_concurrency,
            download_concurrency: asset_download_concurrency
          )
        @profiler = profiler || Profiler.new
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

      def collect(specifier)
        dependency = Dependency.create(specifier: specifier, importer_id: nil, kind: :entrypoint)
        resolved = resolve_dependency(dependency)
        collect_module(resolved.module_id)
      end

      def bundle(entrypoints:)
        loaded_entrypoints =
          @profiler.measure(:entrypoints, count: entrypoints.length) do
            entrypoints.to_h do |entrypoint|
              dependency = Dependency.create(specifier: entrypoint, importer_id: nil, kind: :entrypoint)
              resolved = resolve_dependency(dependency)
              [entrypoint, collect_module(resolved.module_id).id.to_s]
            end
          end
        @profiler.measure(:runtime_dependencies) { collect_all_runtime_dependencies }

        @profiler.measure(:bundle_specs) do
          Runtime::Bundle.new(
            loaded_entrypoints,
            runtime_module_specs,
            runtime_asset_specs,
            source_root: source_dir.to_s
          )
        end
      end

      def assets
        @records.values.select { |record| record.status == :loaded }.flat_map(&:assets).to_h { |asset| [asset.output_path, asset] }
      end

      def asset(output_path)
        assets.fetch(output_path)
      end

      def exports(record_or_module_id)
        module_id = module_id_for(record_or_module_id)
        evaluate_module(module_id).const_get(:Exports)
      end

      def evaluated?(record_or_module_id)
        mod = @mods[module_id_for(record_or_module_id)]
        mod && !mod.is_a?(FailedModule)
      end

      def assets_for(logical_name)
        assets.values.select { |asset| asset.logical_name == logical_name.to_s }
      end

      def assets_for_module(record_or_module_id, type: nil, content_type: nil, recursive: true)
        asset_references_for_module(record_or_module_id, type: type, content_type: content_type, recursive: recursive)
          .map(&:asset)
      end

      def asset_references_for_module(record_or_module_id, type: nil, content_type: nil, recursive: true)
        seen_assets = {}
        module_ids_for_assets(record_or_module_id, recursive: recursive)
          .each_with_index
          .flat_map do |module_id, index|
            module_assets = @records.fetch(module_id).assets
            module_assets.filter_map do |asset|
              next unless asset_matches?(asset, type: type, content_type: content_type)
              next if seen_assets.key?(asset.output_path)

              seen_assets[asset.output_path] = true
              Runtime::AssetReference.new(index:, asset:)
            end
          end
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
          resolved =
            @profiler.measure(:plugin_resolve, plugin: plugin.class.name, specifier: dependency.specifier) do
              plugin.resolve(dependency, self)
            end
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
        evaluated_module_ids = @mods.keys
        changed_module_ids = module_ids_for_paths(changed_paths)
        removed_module_ids = module_ids_for_paths(removed_paths)
        pattern_owner_ids = module_ids_for_watched_paths(changed_paths + removed_paths)
        plugin_owner_ids = plugin_invalidated_module_ids(changed_paths + removed_paths)
        reload_module_ids = (changed_module_ids + pattern_owner_ids + plugin_owner_ids).uniq
        affected_dependents = dependent_closure(reload_module_ids + removed_module_ids)
        errors = []

        removed_module_ids.each do |module_id|
          @records.delete(module_id)
          @mods.delete(module_id)
        end

        reloaded_module_ids =
          reload_module_ids.filter_map do |module_id|
            if evaluated_module_ids.include?(module_id)
              load_module(module_id, force: true)
            else
              collect_module(module_id, force: true)
            end
            module_id
          rescue => e
            mark_module_failed(module_id, e)
            errors << [module_id, e]
            nil
          end
        failed_reload_ids = errors.map(&:first) & reload_module_ids
        blocked_dependent_ids = dependent_closure(failed_reload_ids)
        blocked_dependent_ids.each { |module_id| @mods.delete(module_id) }

        reevaluated_module_ids =
          affected_dependents.filter_map do |module_id|
            next if removed_module_ids.include?(module_id)
            next if reload_module_ids.include?(module_id)
            next if blocked_dependent_ids.include?(module_id)

            if evaluated_module_ids.include?(module_id)
              load_module(module_id, reevaluate: true)
              module_id
            else
              collect_module(module_id, force: true)
              nil
            end
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

        if !force && !reevaluate
          return @loading_tasks.fetch(module_id).wait if @loading_tasks.key?(module_id)

          begin
            in_flight_load = InFlightLoad.create
            @loading_tasks[module_id] = in_flight_load
            result = AsyncResult.capture { load_module_now(module_id, force: force, reevaluate: reevaluate) }
            in_flight_load.finish(result)
            return AsyncResult.unwrap(result)
          ensure
            @loading_tasks.delete(module_id) if @loading_tasks[module_id].equal?(in_flight_load)
          end
        end

        load_module_now(module_id, force: force, reevaluate: reevaluate)
      end

      def load_module_now(module_id, force: false, reevaluate: false)
        with_loading_stack(module_id) do
          loaded_source = read_module_source(module_id)
          source = loaded_source.source
          source_hash = loaded_source.source_hash || Hashing.hexdigest(source)
          cached = @records[module_id]

          raise_failed_module!(cached)

          if cached&.source_hash == source_hash && !force && !reevaluate
            evaluate_module(module_id) unless @mods.key?(module_id)
            return cached
          end

          transform = loaded_source.transform || transform_module_source(module_id, source)
          resolved_dependencies = resolve_transform_dependencies(transform)
          dependency_records = load_eager_dependency_records(resolved_dependencies)
          transform = finalize_transform_result(module_id, transform, resolved_dependencies, dependency_records)
          assert_supported_transform!(module_id, source, transform)
          transformed_hash = Hashing.hexdigest(transform.code)
          mod = instantiate_module(module_id, transform, resolved_dependencies, dependency_records, cached)
          record = build_module_record(module_id, source, source_hash, transformed_hash, transform, resolved_dependencies, mod)

          @records[module_id] = record
          @mods[module_id] = mod
          record
        end
      end

      def collect_module(module_id, force: false)
        raise_import_cycle_if_present(module_id) unless force

        if !force
          return @loading_tasks.fetch(module_id).wait if @loading_tasks.key?(module_id)

          begin
            in_flight_load = InFlightLoad.create
            @loading_tasks[module_id] = in_flight_load
            result = AsyncResult.capture { collect_module_now(module_id, force: force) }
            in_flight_load.finish(result)
            return AsyncResult.unwrap(result)
          ensure
            @loading_tasks.delete(module_id) if @loading_tasks[module_id].equal?(in_flight_load)
          end
        end

        collect_module_now(module_id, force: force)
      end

      def collect_module_now(module_id, force: false)
        with_loading_stack(module_id) do
          loaded_source = read_module_source(module_id)
          source = loaded_source.source
          source_hash = loaded_source.source_hash || Hashing.hexdigest(source)
          cached = @records[module_id]

          raise_failed_module!(cached)

          return cached if cached&.source_hash == source_hash && !force

          transform = loaded_source.transform || transform_module_source(module_id, source)
          resolved_dependencies = resolve_transform_dependencies(transform)
          dependency_records = collect_eager_dependency_records(resolved_dependencies)
          transform = finalize_transform_result(module_id, transform, resolved_dependencies, dependency_records)
          assert_supported_transform!(module_id, source, transform)
          transformed_hash = Hashing.hexdigest(transform.code)
          record = build_module_record(module_id, source, source_hash, transformed_hash, transform, resolved_dependencies, cached)

          @records[module_id] = record
          @mods.delete(module_id)
          record
        end
      end

      def evaluate_module(module_id)
        return @mods.fetch(module_id) if @mods.key?(module_id)

        record = @records.fetch(module_id) { collect_module(module_id) }
        raise_failed_module!(record)
        evaluate_eager_dependencies(record.resolved_dependencies)
        dependency_records = dependency_records_for(eager_dependencies(record.resolved_dependencies))
        mod =
          Runtime::Mod.new(
            module_id.to_s,
            record.transformed_source,
            imports: imports_for(record.resolved_dependencies, dependency_records),
            source_map: record.source_map,
            version: record.version,
            eval_path: eval_path_for(module_id)
          )

        @mods[module_id] = mod
      end

      def tsort_each_node(&block)
        @records.each_key(&block)
      end

      def tsort_each_child(node, &block)
        record = @records.fetch(node)
        return if record.status != :loaded

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
          record = @records.fetch(module_id)
          queue.concat(record.resolved_dependencies.map(&:module_id)) if record.status == :loaded
        end

        seen.to_a
      end

      def module_ids_for_assets(record_or_module_id, recursive:)
        return Array(record_or_module_id).map { |module_ref| module_id_for(module_ref) }.uniq unless recursive

        seen = []
        Array(record_or_module_id).flat_map do |module_ref|
          ordered_module_ids_for_assets(module_id_for(module_ref), seen)
        end
      end

      def ordered_module_ids_for_assets(module_id, seen)
        return [] if seen.include?(module_id)
        return [] unless @records.key?(module_id)

        seen << module_id
        record = @records.fetch(module_id)
        dependency_ids = record.resolved_dependencies.map(&:module_id)

        if module_id.extname == ".css"
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
        loaded = load_source(module_id, @resolver.absolute_path(module_id))
        return loaded if loaded.is_a?(LoadResult)

        LoadResult.new(loaded, nil, nil)
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
          eval_path: eval_path_for(module_id)
        )
      end

      def eval_path_for(module_id)
        return module_id.to_s unless module_id.scheme == :app

        source_dir.join(module_id.path).to_s
      end

      def imports_for(resolved_dependencies, dependency_records)
        resolved_dependencies.to_h do |resolved_dependency|
          value =
            if resolved_dependency.dependency.eager
              record = dependency_records.fetch(resolved_dependency.dependency.id)
              raise_failed_module!(record)
              import_value(resolved_dependency, record)
            else
              Runtime::LazyImport.new do
                evaluate_module(resolved_dependency.module_id)
                record = @records.fetch(resolved_dependency.module_id)
                raise_failed_module!(record)
                import_value(resolved_dependency, record)
              end
            end

          [resolved_dependency.dependency.id, value]
        end
      end

      def evaluate_eager_dependencies(resolved_dependencies)
        eager_dependencies(resolved_dependencies).each do |resolved_dependency|
          evaluate_module(resolved_dependency.module_id)
        end
      end

      def dependency_records_for(resolved_dependencies)
        resolved_dependencies.to_h do |resolved_dependency|
          [
            resolved_dependency.dependency.id,
            @records.fetch(resolved_dependency.module_id) { collect_module(resolved_dependency.module_id) }
          ]
        end
      end

      def build_module_record(module_id, source, source_hash, transformed_hash, transform, resolved_dependencies, cached_or_mod)
        version =
          if cached_or_mod.is_a?(Runtime::Mod)
            cached_or_mod.version
          elsif cached_or_mod
            cached_or_mod.version + 1
          else
            0
          end

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
          transform.metadata,
          version,
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

      def plugin_invalidated_module_ids(paths)
        @plugins
          .flat_map { |plugin| plugin.invalidate_module_ids(paths, self) }
          .uniq
          .select { |module_id| graph_relevant_module_id?(module_id) }
      end

      def graph_relevant_module_id?(module_id)
        @records.key?(module_id) || @records.any? do |_candidate_id, record|
          record.resolved_dependencies.any? { |dependency| dependency.module_id == module_id }
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
          wait_for_dependency_tasks(
            resolved_dependencies.map do |resolved_dependency|
              [
                resolved_dependency.dependency.id,
                task.async { AsyncResult.capture { load_module(resolved_dependency.module_id) } }
              ]
            end
          )
        end
      end

      def collect_dependency_records(resolved_dependencies)
        return {} if resolved_dependencies.empty?

        if resolved_dependencies.length == 1
          resolved_dependency = resolved_dependencies.fetch(0)
          return {
            resolved_dependency.dependency.id => collect_module(resolved_dependency.module_id)
          }
        end

        with_async_task do |task|
          wait_for_dependency_tasks(
            resolved_dependencies.map do |resolved_dependency|
              [
                resolved_dependency.dependency.id,
                task.async { AsyncResult.capture { collect_module(resolved_dependency.module_id) } }
              ]
            end
          )
        end
      end

      def wait_for_dependency_tasks(tasks)
        first_error = nil

        tasks.each_with_object({}) do |(dependency_id, child_task), records|
          records[dependency_id] = AsyncResult.unwrap(child_task.wait)
        rescue => e
          first_error ||= e
        end.tap do
          raise first_error if first_error
        end
      end

      def mark_module_failed(module_id, error)
        cached = @records[module_id]
        loaded_source =
          begin
            read_module_source(module_id)
          rescue
            LoadResult.new(cached&.source || "", nil, nil)
          end
        source = loaded_source.source
        source_hash = loaded_source.source_hash || Hashing.hexdigest(source)
        version = cached ? cached.version + 1 : 0

        @records[module_id] =
          ModuleRecord.new(
            module_id,
            source_hash,
            "",
            [],
            [],
            source,
            "",
            nil,
            [],
            [],
            {error: error},
            version,
            :failed
          )
        @mods[module_id] = FailedModule.new(error)
      end

      def raise_failed_module!(record)
        raise record.metadata.fetch(:error) if record&.status == :failed
      end

      def collect_eager_dependency_records(resolved_dependencies)
        collect_dependency_records(eager_dependencies(resolved_dependencies))
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

      def collect_all_runtime_dependencies
        queue = @records.values.flat_map(&:resolved_dependencies)

        until queue.empty?
          resolved_dependency = queue.shift
          next if @records.key?(resolved_dependency.module_id)

          record = collect_module(resolved_dependency.module_id)
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

      def load_source(module_id, absolute_path)
        @plugins.each do |plugin|
          loaded =
            @profiler.measure(:plugin_load, plugin: plugin.class.name, module_id: module_id.to_s) do
              plugin.load(module_id, self)
            end
          return loaded if loaded
        end
        return @virtual_sources.fetch(module_id) if @virtual_sources.key?(module_id)

        absolute_path.binread
      end

      def transform(module_id, source)
        @plugins.reduce(TransformResult.identity(source)) do |current, plugin|
          result =
            @profiler.measure(:plugin_transform, plugin: plugin.class.name, module_id: module_id.to_s) do
              plugin.transform(module_id, current.code, self)
            end || TransformResult.identity(current.code)
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
          @profiler.measure(:plugin_finalize, plugin: plugin.class.name, module_id: module_id.to_s) do
            plugin.finalize(module_id, current, resolved_dependencies, dependency_records, self)
          end
        end
      end

      def import_value(resolved_dependency, record)
        raise_failed_module!(record)

        value = plugin_import_value(resolved_dependency, record)
        return value unless value.nil?

        @mods.fetch(record.id).const_get(:Exports)
      end

      def plugin_import_value(resolved_dependency, record)
        @plugins.each do |plugin|
          value =
            @profiler.measure(:plugin_import_value, plugin: plugin.class.name, module_id: record.id.to_s) do
              plugin.import_value(resolved_dependency, record, self)
            end
          return value unless value.nil?
        end

        nil
      end

      def plugin_runtime_import_value(resolved_dependency, record)
        @plugins.each do |plugin|
          value =
            @profiler.measure(:plugin_runtime_import_value, plugin: plugin.class.name, module_id: record.id.to_s) do
              plugin.runtime_import_value(resolved_dependency, record, self)
            end
          return value unless value.nil?
        end

        nil
      end
    end
  end
end
