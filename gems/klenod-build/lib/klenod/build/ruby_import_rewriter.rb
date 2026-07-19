# frozen_string_literal: true

require "ripper"
require "syntax_tree"

require_relative "dependency"
require_relative "errors"

module Klenod
  module Build
    class RubyImportRewriter
      ImportCall =
        Data.define(:specifier, :location, :dynamic, :method_name) do
          def eager
            RubyImportRewriter::IMPORT_METHODS.fetch(method_name).fetch(:eager)
          end

          def replacement
            RubyImportRewriter::IMPORT_METHODS.fetch(method_name).fetch(:replacement)
          end
        end
      Result = Data.define(:code, :dependencies)

      IMPORT_METHODS = {
        "import" => {
          replacement: "__klenod_import__",
          eager: true
        },
        "lazy_import" => {
          replacement: "__klenod_lazy_import__",
          eager: false
        }
      }.freeze
      IMPORT_SOURCE_PATTERN = /(?<![A-Za-z0-9_])(?:import|lazy_import)\s*(?:\(|["'])/
      FAST_LITERAL_IMPORT_PATTERN = /(?<![A-Za-z0-9_])(import|lazy_import)\s*\(\s*("(?:\\.|[^"\\#])*")\s*\)/

      def initialize(module_id:, kind:, profiler: nil, dependency_id_offset: 0)
        @module_id = module_id
        @kind = kind
        @profiler = profiler
        @dependency_id_offset = dependency_id_offset
      end

      def rewrite(code)
        return Result.new(code, []) unless import_source?(code)
        fast_result = rewrite_literal_import_calls(code)
        return fast_result if fast_result

        ast = measure(:ruby_import_parse) { SyntaxTree.parse(code) }
        calls = measure(:ruby_import_scan) { import_calls(ast) }
        dependencies =
          calls.each_with_index.map do |call, index|
            if call.dynamic
              raise DynamicImportError, "Only literal import(\"...\") calls are supported in #{@module_id}"
            end

            Dependency
              .create(
                specifier: call.specifier,
                importer_id: @module_id,
                kind: @kind,
                loc: call.location
              )
              .with(eager: call.eager)
              .with(id: "#{@module_id}:dependency:#{@dependency_id_offset + index}")
          end

        rewritten = measure(:ruby_import_rewrite_source) { rewrite_import_calls(code, calls, dependencies) }
        Result.new(rewritten, dependencies)
      end

      private

      def import_source?(code)
        code.match?(IMPORT_SOURCE_PATTERN)
      end

      def rewrite_literal_import_calls(code)
        matches = []
        code.to_enum(:scan, IMPORT_SOURCE_PATTERN).each do
          start = Regexp.last_match.begin(0)
          match = FAST_LITERAL_IMPORT_PATTERN.match(code, start)
          return nil unless match && match.begin(0) == start

          matches << match
        end
        return nil if matches.empty?
        return nil unless bare_import_tokens?(code, matches)

        dependencies =
          matches.each_with_index.map do |match, index|
            specifier =
              begin
                match[2].undump
              rescue RuntimeError
                return nil
              end

            Dependency
              .create(
                specifier: specifier,
                importer_id: @module_id,
                kind: @kind
              )
              .with(eager: IMPORT_METHODS.fetch(match[1]).fetch(:eager))
              .with(id: "#{@module_id}:dependency:#{@dependency_id_offset + index}")
          end

        rewritten =
          matches
            .zip(dependencies)
            .reverse_each
            .each_with_object(code.dup) do |(match, dependency), source|
              replacement = IMPORT_METHODS.fetch(match[1]).fetch(:replacement)
              source[match.begin(0)...match.end(0)] = "#{replacement}(#{dependency.id.inspect})"
            end

        Result.new(rewritten, dependencies)
      end

      def bare_import_tokens?(code, matches)
        match_starts = matches.to_h { |match| [match.begin(1), match[1]] }
        return true if match_starts.empty?

        line_offsets = line_offsets_for(code)
        previous_significant_token = nil
        matched = {}

        Ripper.lex(code).each do |(line, column), type, token, _state|
          offset = line_offsets.fetch(line - 1) + column
          expected = match_starts[offset]
          if expected
            return false unless type == :on_ident && token == expected
            return false if receiver_token?(previous_significant_token)

            matched[offset] = true
          end

          previous_significant_token = [type, token] unless insignificant_token?(type)
        end

        matched.length == match_starts.length
      end

      def receiver_token?(token)
        token == [:on_period, "."] || token == [:on_op, "::"] || token == [:on_op, "&."]
      end

      def line_offsets_for(code)
        offsets = [0]
        code.each_line(chomp: false) { |line| offsets << offsets.last + line.length }
        offsets
      end

      def insignificant_token?(type)
        type == :on_sp || type == :on_ignored_nl || type == :on_nl || type == :on_comment
      end

      def measure(name, &block)
        return yield unless @profiler

        @profiler.measure(name, module_id: @module_id.to_s, kind: @kind, &block)
      end

      def import_calls(node)
        calls = []
        walk(node) do |child|
          if child.instance_of?(::SyntaxTree::CallNode)
            next unless child.instance_variable_get(:@receiver).nil?
            next unless IMPORT_METHODS.key?(child.instance_variable_get(:@message)&.value)

            calls << build_import_call(child)
          elsif child.instance_of?(::SyntaxTree::Command)
            next unless IMPORT_METHODS.key?(child.instance_variable_get(:@message)&.value)

            calls << build_import_command(child)
          end
        end
        calls
      end

      def build_import_call(node)
        arguments = node.instance_variable_get(:@arguments)
        parts = arguments&.instance_variable_get(:@arguments)&.instance_variable_get(:@parts) || []
        build_import_from_parts(node, parts)
      end

      def build_import_command(node)
        arguments = node.instance_variable_get(:@arguments)
        parts = arguments&.instance_variable_get(:@parts) || []
        build_import_from_parts(node, parts)
      end

      def build_import_from_parts(node, parts)
        first = unwrap_paren(parts.first)
        string_parts = first&.instance_variable_get(:@parts)
        literal =
          (parts.length == 1) &&
          first&.class&.name == "SyntaxTree::StringLiteral" &&
          string_parts&.length == 1 &&
          string_parts.first.instance_of?(::SyntaxTree::TStringContent)

        ImportCall.new(
          literal ? string_parts.first.value : nil,
          node.instance_variable_get(:@location),
          !literal,
          node.instance_variable_get(:@message).value
        )
      end

      def unwrap_paren(node)
        return node unless node.instance_of?(::SyntaxTree::Paren)

        statements = node.instance_variable_get(:@contents)
        body = statements&.instance_variable_get(:@body) || []
        (body.length == 1) ? body.first : node
      end

      def rewrite_import_calls(code, calls, dependencies)
        calls
          .zip(dependencies)
          .reverse_each
          .each_with_object(code.dup) do |(call, dependency), rewritten|
            next rewritten if call.dynamic

            location = call.location
            original = code[location.start_char...location.end_char]
            unless original.match?(/\A#{Regexp.escape(call.method_name)}\s*\(/)
              raise DynamicImportError, "Could not safely rewrite import at #{location.start_line}:#{location.start_column}"
            end

            rewritten[location.start_char...location.end_char] =
              "#{call.replacement}(#{dependency.id.inspect})"
          end
      end

      def walk(value, &block)
        yield value

        case value
        when Array
          value.each { |item| walk(item, &block) }
        else
          return unless value.respond_to?(:instance_variables)

          value.instance_variables.each do |ivar|
            walk(value.instance_variable_get(ivar), &block)
          end
        end
      end
    end
  end
end
