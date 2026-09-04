# frozen_string_literal: true

require "covered"
require "covered/markdown_summary"
require "covered/statistics"

require_relative "config"

module Klenod
  module Test
    class CoverageResult < Covered::Wrapper
      def initialize(output, context:, plugin:)
        super(output)
        @modules_by_path = context.graph.mods.to_h do |module_id, mod|
          [File.expand_path(mod.eval_path), [module_id, mod]]
        end
        @plugin = plugin
      end

      def each
        return enum_for unless block_given?

        super do |coverage|
          mapped = map(coverage)
          yield mapped if mapped
        end
      end

      private

      attr_reader :modules_by_path, :plugin

      def map(coverage)
        module_id, mod = modules_by_path[File.expand_path(coverage.path)]
        return unless module_id&.scheme == :app
        return if plugin.test_module_id?(module_id)

        if mod.source_map
          map_source(coverage, mod.source_map)
        elsif module_id.extname == ".rb"
          coverage
        end
      end

      def map_source(coverage, source_map)
        counts = Array.new(source_map.input.lines.count + 1)
        input_line = nil

        coverage.counts.each_with_index do |count, output_line|
          input_line = source_map.marks_by_output_line[output_line]&.line || input_line
          next if count.nil?
          next unless input_line

          counts[input_line] = [counts[input_line] || 0, count].max
        end

        return unless counts.any? { |count| !count.nil? }

        Covered::Coverage.new(Covered::Source.for(coverage.path), counts)
      end
    end

    class CoverageRunner
      REPORTS = {
        brief: Covered::BriefSummary,
        partial: Covered::PartialSummary,
        full: Covered::FullSummary,
        markdown: Covered::MarkdownSummary,
        quiet: Covered::Quiet
      }.freeze

      def initialize(context:, plugin:, config:, output: $stdout)
        @context = context
        @plugin = plugin
        @config = config
        @output = output
      end

      def call
        policy = Covered::Policy.new
        policy.root(context.graph.source_dir.to_s)
        policy.start
        status = begin
          Integer(yield)
        ensure
          policy.finish
        end

        result = CoverageResult.new(policy, context:, plugin:)
        REPORTS.fetch(config.report).new.call(result, output)
        validate_minimum(result, status)
      end

      private

      attr_reader :context, :plugin, :config, :output

      def validate_minimum(result, status)
        return status unless config.minimum

        statistics = Covered::Statistics.new
        result.each { |coverage| statistics << coverage }
        statistics.validate!(config.minimum / 100.0)
        status
      rescue Covered::CoverageError => error
        output.puts
        output.puts error.message
        status.zero? ? 1 : status
      end
    end
  end
end
