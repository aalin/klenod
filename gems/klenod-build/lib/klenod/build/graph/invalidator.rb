# frozen_string_literal: true

module Klenod
  module Build
    class Graph
      class Invalidator
        def initialize(graph, resolver, source_loader:)
          @graph = graph
          @resolver = resolver
          @source_loader = source_loader
        end

        def invalidate_paths(changed_paths, removed_paths: [])
          @resolver.clear_cache
          previous_assets = graph.assets
          evaluated_module_ids = mods.keys
          changed_module_ids = module_ids_for_paths(changed_paths)
          removed_module_ids = module_ids_for_paths(removed_paths)
          failed_retry_ids = failed_module_ids - removed_module_ids
          imported_module_ids = records.each_key.select { |module_id| graph.dependents(module_id).any? }
          pattern_owner_ids = module_ids_for_watched_paths(changed_paths + removed_paths)
          plugin_owner_ids = plugin_invalidated_module_ids(changed_paths + removed_paths)
          reload_module_ids = (changed_module_ids + failed_retry_ids + pattern_owner_ids + plugin_owner_ids).uniq
          affected_dependents = dependent_closure(reload_module_ids + removed_module_ids)
          errors = []

          removed_module_ids.each do |module_id|
            graph.remove_record(module_id)
            mods.delete(module_id)
          end

          failed_reload_ids = []
          reloaded_module_ids =
            reload_module_ids.filter_map do |module_id|
              if orphaned_failure?(module_id, imported_module_ids)
                graph.remove_record(module_id)
                mods.delete(module_id)
                next
              end

              if evaluated_module_ids.include?(module_id)
                graph.load_module(module_id, force: true)
              else
                graph.collect_module(module_id, force: true)
              end
              module_id
            rescue StandardError, ScriptError => e
              # ScriptError too: a syntax error in a module is not a
              # StandardError, and letting it escape here kills the watcher
              # thread rather than reporting the module that failed.
              mark_module_failed(module_id, e)
              failed_reload_ids << module_id
              record_error(errors, module_id, e)
              nil
            end
          blocked_dependent_ids = dependent_closure(failed_reload_ids)
          blocked_dependent_ids.each { |module_id| mods.delete(module_id) }

          reevaluated_module_ids =
            affected_dependents.filter_map do |module_id|
              next if removed_module_ids.include?(module_id)
              next if reload_module_ids.include?(module_id)
              next if blocked_dependent_ids.include?(module_id)

              if evaluated_module_ids.include?(module_id)
                graph.load_module(module_id, reevaluate: true)
                module_id
              else
                graph.collect_module(module_id, force: true)
                nil
              end
            rescue StandardError, ScriptError => e
              record_error(errors, module_id, e)
              nil
            end
          asset_updates = diff_assets(previous_assets, graph.assets)
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

        private

        # One failure, reported once. A module whose dependency already failed
        # in this invalidation re-raises that same error when it reloads, so a
        # broken companion would otherwise be reported once for itself and
        # again for every module that imports it.
        def record_error(errors, module_id, error)
          return if errors.any? { |(_id, recorded)| recorded.equal?(error) }

          errors << [module_id, error]
        end

        attr_reader :graph, :resolver, :source_loader

        def records
          graph.records
        end

        def mods
          graph.mods
        end

        def module_ids_for_paths(paths)
          paths
            .flat_map { |path| module_ids_for_path(path) }
            .select { |module_id| records.key?(module_id) }
            .uniq
        end

        def module_ids_for_watched_paths(paths)
          relative_paths =
            paths.filter_map do |path|
              Pathname.new(path).expand_path.relative_path_from(resolver.source_dir).to_s
            rescue ArgumentError
              nil
            end

          records.filter_map do |module_id, record|
            module_id if relative_paths.any? { |path| record.watched_patterns.any? { |pattern| pattern.match?(path) } }
          end
        end

        # A failed record keeps no dependency links, so nothing ties it to the file
        # that broke it: a missing import, or a new dependency that fails to parse.
        # Retry every failed module on each change. Failures are rare, and a retry
        # that fails again reports its error again.
        def failed_module_ids
          records.filter_map { |module_id, record| module_id if record.status == :failed }
        end

        # A failed module whose last importer dropped it earlier in this update.
        # Nothing can demand it any more, so retrying it would report its error
        # on every change. Its record goes; importing it again collects it anew.
        # A failed entry never had an importer and keeps being retried.
        def orphaned_failure?(module_id, imported_module_ids)
          records[module_id]&.status == :failed &&
            imported_module_ids.include?(module_id) &&
            graph.dependents(module_id).empty?
        end

        def plugin_invalidated_module_ids(paths)
          graph.plugins
            .flat_map { |plugin| plugin.invalidate_module_ids(paths, graph) }
            .uniq
            .select { |module_id| graph_relevant_module_id?(module_id) }
        end

        def graph_relevant_module_id?(module_id)
          records.key?(module_id) || records.any? do |_candidate_id, record|
            record.resolved_dependencies.any? { |dependency| dependency.module_id == module_id }
          end
        end

        def module_ids_for_path(path)
          absolute_path = Pathname.new(path).expand_path
          relative = absolute_path.relative_path_from(resolver.source_dir).to_s

          records.each_key.select { |module_id| module_id.path == relative }
        rescue ArgumentError
          []
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
          graph.dependents(module_id)
        end

        def mark_module_failed(module_id, error)
          cached = records[module_id]
          loaded_source =
            begin
              source_loader.call(module_id)
            rescue
              LoadResult.new(cached&.source || "", nil, nil)
            end
          source = loaded_source.source
          source_hash = loaded_source.source_hash || Hashing.hexdigest(source)
          version = cached ? cached.version + 1 : 0

          graph.store_record(
            module_id,
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
          )
          # Only an evaluated module needs the placeholder, so demand raises the
          # error instead of serving stale exports. The failed record already
          # covers a collected-only module, and a placeholder would make the
          # next update treat it as evaluated and run its code.
          mods[module_id] = FailedModule.new(error) if mods.key?(module_id)
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
      end
    end
  end
end
