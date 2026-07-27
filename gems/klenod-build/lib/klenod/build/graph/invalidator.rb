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
          pattern_owner_ids = module_ids_for_watched_paths(changed_paths + removed_paths)
          plugin_owner_ids = plugin_invalidated_module_ids(changed_paths + removed_paths)
          reload_module_ids = (changed_module_ids + pattern_owner_ids + plugin_owner_ids).uniq
          affected_dependents = dependent_closure(reload_module_ids + removed_module_ids)
          errors = []

          removed_module_ids.each do |module_id|
            records.delete(module_id)
            mods.delete(module_id)
          end

          reloaded_module_ids =
            reload_module_ids.filter_map do |module_id|
              if evaluated_module_ids.include?(module_id)
                graph.load_module(module_id, force: true)
              else
                graph.collect_module(module_id, force: true)
              end
              module_id
            rescue => e
              mark_module_failed(module_id, e)
              errors << [module_id, e]
              nil
            end
          failed_reload_ids = errors.map(&:first) & reload_module_ids
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
            rescue => e
              errors << [module_id, e]
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

        attr_reader :graph, :resolver, :source_loader

        def records
          graph.records
        end

        def mods
          graph.mods
        end

        def module_ids_for_paths(paths)
          paths
            .map { |path| module_id_for_path(path) }
            .compact
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

        def module_id_for_path(path)
          absolute_path = Pathname.new(path).expand_path
          relative = absolute_path.relative_path_from(resolver.source_dir).to_s

          records.each_key.find { |module_id| module_id.path == relative }
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
          records.filter_map do |candidate_id, record|
            candidate_id if record.resolved_dependencies.any? { |dependency| dependency.module_id == module_id }
          end
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

          records[module_id] =
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
          mods[module_id] = FailedModule.new(error)
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
