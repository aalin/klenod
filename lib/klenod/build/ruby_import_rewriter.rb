# frozen_string_literal: true

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

      def initialize(module_id:, kind:)
        @module_id = module_id
        @kind = kind
      end

      def rewrite(code)
        ast = SyntaxTree.parse(code)
        calls = import_calls(ast)
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
              .with(id: "#{@module_id}:dependency:#{index}")
          end

        Result.new(rewrite_import_calls(code, calls, dependencies), dependencies)
      end

      private

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
