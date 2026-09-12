# frozen_string_literal: true

require "async"
require "async/semaphore"

require "klenod/build/dependency"
require "klenod/build/module_id"

module Klenod
  module LSP
    # The collected module graph behind cross-file features.
    #
    # Roots are the configured entrypoints plus every Ruby and Haml file under
    # the source directory, so orphan components and test files are indexed
    # too. Lazy dependencies such as router pages are walked as well. Nothing
    # is ever evaluated. Root collections are serialized so two walks cannot
    # deadlock on a shared import cycle; the graph parallelizes inside each.
    class GraphIndex
      ROOT_EXTENSIONS = [".rb", ".haml"].freeze

      attr_reader :failed

      def initialize(workspace:, logger:, entrypoints: [])
        @workspace = workspace
        @graph = workspace.context.graph
        @entrypoints = entrypoints
        @logger = logger
        @failed = {}
        @unresolved_entrypoints = []
        @semaphore = Async::Semaphore.new(1)
        @task = nil
      end

      # Collect every root in the background, yielding to other work between
      # roots. `progress` responds to `begin(total)`, `report(done, total)`,
      # and `finish`; the block runs once the pass completed.
      def start(parent_task, progress: nil, &on_complete)
        @task =
          parent_task.async do |task|
            roots = root_module_ids
            progress&.begin(roots.length)
            roots.each_with_index do |module_id, index|
              collect_root(module_id)
              progress&.report(index + 1, roots.length)
              task.yield
            end
            progress&.finish
            on_complete&.call
          rescue => error
            progress&.finish
            @logger.error { "Graph index failed: #{error.class}: #{error.message}" }
          end
      end

      def stop
        @task&.stop
      end

      def running?
        @task ? !@task.finished? : false
      end

      def wait
        @task&.wait
      end

      def records
        @graph.records
      end

      def record(module_id)
        @graph.records[module_id]
      end

      def dependents(module_id)
        @graph.dependents(module_id)
      end

      # Collect one module and everything reachable from it, remembering
      # failures so they can be retried when files change.
      def ensure_collected(module_id)
        @semaphore.acquire { collect_root(module_id) }
      end

      # Apply file changes through the build's own invalidation, collect new
      # modules, retry earlier failures, and return the ids whose records may
      # have changed, including their dependents.
      def invalidate(changed_paths, removed_paths)
        @semaphore.acquire do
          result = @workspace.context.invalidate_paths(changed_paths, removed_paths: removed_paths)
          affected = Set.new
          [result.changed_module_ids, result.removed_module_ids, result.reloaded_module_ids, result.reevaluated_module_ids].each do |ids|
            ids.each { |module_id| affected << module_id.to_s }
          end
          result.errors.each do |module_id, error|
            next unless module_id

            @failed[module_id.to_s] = error
            affected << module_id.to_s
          end

          changed_paths.each do |path|
            module_id = @workspace.module_id_for_path(path)
            next unless module_id && ROOT_EXTENSIONS.include?(module_id.extname)
            next if @graph.records.key?(module_id)

            collect_root(module_id)
            affected << module_id.to_s
          end

          # A retried module is affected whether or not it recovers: its
          # diagnostics changed either way. The retry forces a re-collect,
          # because a module that failed after its record was stored still has
          # that stale record.
          @failed.keys.each do |module_id_string|
            collect_root(Klenod::Build::ModuleId.new(module_id_string), force: true)
            affected << module_id_string
          end
          @unresolved_entrypoints.dup.each do |specifier|
            module_id = resolve_entrypoint(specifier)
            affected << module_id.to_s if module_id && collect_root(module_id)
          end

          dependents_closure(affected)
        end
      end

      private

      def root_module_ids
        roots = []
        @entrypoints.each do |specifier|
          module_id = resolve_entrypoint(specifier)
          roots << module_id if module_id
        end
        Dir.glob("**/*", base: @workspace.source_dir).sort.each do |relative|
          next if relative.split("/").any? { |segment| segment.start_with?(".") }
          next unless ROOT_EXTENSIONS.include?(File.extname(relative))
          next unless File.file?(File.join(@workspace.source_dir, relative))

          roots << Klenod::Build::ModuleId.new("app:/#{relative}")
        end
        roots.uniq
      end

      def resolve_entrypoint(specifier)
        dependency = Klenod::Build::Dependency.create(specifier: specifier, importer_id: nil, kind: :entrypoint)
        module_id = @graph.resolve_dependency(dependency).module_id
        @unresolved_entrypoints.delete(specifier)
        module_id
      rescue Klenod::Build::ResolveError => error
        @unresolved_entrypoints << specifier unless @unresolved_entrypoints.include?(specifier)
        @logger.warn { "Entrypoint #{specifier.inspect} did not resolve: #{error.message}" }
        nil
      end

      # Returns true when the root is collected, false when it failed.
      def collect_root(module_id, force: false)
        if force
          @graph.collect_module(module_id, force: true)
        else
          @graph.records[module_id] || @graph.collect_module(module_id)
        end
        @failed.delete(module_id.to_s)
        @graph.collect_reachable(module_id) do |reached_id, error|
          if error
            @failed[reached_id.to_s] = error
          else
            @failed.delete(reached_id.to_s)
          end
        end
        true
      rescue StandardError, ScriptError => error
        @failed[module_id.to_s] = error
        false
      end

      def dependents_closure(module_id_strings)
        seen = Set.new(module_id_strings)
        queue = module_id_strings.to_a

        until queue.empty?
          module_id_string = queue.shift
          @graph.dependents(Klenod::Build::ModuleId.new(module_id_string)).each do |dependent_id|
            queue << dependent_id.to_s if seen.add?(dependent_id.to_s)
          end
        end

        seen
      end
    end
  end
end
