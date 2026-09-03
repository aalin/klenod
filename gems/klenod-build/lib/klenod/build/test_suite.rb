# frozen_string_literal: true

module Klenod
  module Build
    TestSelection = Data.define(:test_paths, :removed_test_paths) do
      def empty?
        test_paths.empty? && removed_test_paths.empty?
      end
    end

    class TestSuite
      def initialize(context:, plugin:)
        @context = context
        @plugin = plugin
        @dependency_ids = {}
        @failed_test_ids = Set.new
      end

      def collect
        test_ids = discover
        test_ids.each { |test_id| index(test_id) }
        selection(test_ids)
      end

      def update(event)
        previous_test_ids = @dependency_ids.keys.to_set
        current_test_ids = discover.to_set
        removed_test_ids = previous_test_ids - current_test_ids
        added_test_ids = current_test_ids - previous_test_ids
        affected_module_ids = update_module_ids(event)
        affected_test_ids =
          @dependency_ids.filter_map do |test_id, dependency_ids|
            test_id if current_test_ids.include?(test_id) && dependency_ids.intersect?(affected_module_ids)
          end

        test_ids = (added_test_ids + affected_test_ids + @failed_test_ids).select { |test_id| current_test_ids.include?(test_id) }
        removed_test_ids.each { |test_id| remove(test_id) }
        test_ids.each { |test_id| index(test_id) }

        selection(test_ids, removed_test_ids)
      end

      private

      attr_reader :context, :plugin

      def discover
        plugin.discover(source_dir: context.graph.source_dir)
      end

      def index(test_id)
        dependency_ids = Set[test_id]
        @dependency_ids[test_id] = dependency_ids
        collect_dependencies(test_id, dependency_ids)
        @failed_test_ids.delete(test_id)
      rescue
        @failed_test_ids << test_id
      end

      def collect_dependencies(module_id, dependency_ids)
        record = context.graph.records[module_id] || context.graph.collect_module(module_id)

        record.resolved_dependencies.each do |dependency|
          dependency_id = dependency.module_id
          next unless dependency_ids.add?(dependency_id)

          collect_dependencies(dependency_id, dependency_ids)
        end
      end

      def remove(test_id)
        @dependency_ids.delete(test_id)
        @failed_test_ids.delete(test_id)
      end

      def update_module_ids(event)
        result = event.result
        Set.new(
          result.changed_module_ids +
            result.removed_module_ids +
            result.reloaded_module_ids +
            result.reevaluated_module_ids
        )
      end

      def selection(test_ids, removed_test_ids = [])
        TestSelection.new(
          test_ids.map(&:relative_path).sort.freeze,
          removed_test_ids.map(&:relative_path).sort.freeze
        )
      end
    end
  end
end
