# frozen_string_literal: true

require "syntax_tree"

require_relative "../dependency"
require_relative "../errors"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class RubyPlugin < Plugin
        ImportCall = Data.define(:specifier, :location, :dynamic)
        IMPORT_RE = /\Aimport\s*\(/

        def transform(module_id, code, _context)
          return TransformResult.identity(code) unless module_id.extname == ".rb"

          ast = SyntaxTree.parse(code)
          calls = import_calls(ast)

          dependencies =
            calls.each_with_index.map do |call, index|
              if call.dynamic
                raise DynamicImportError, "Only literal import(\"...\") calls are supported in #{module_id}"
              end

              Dependency
                .create(
                  specifier: call.specifier,
                  importer_id: module_id,
                  kind: :ruby_import,
                  loc: call.location
                )
                .with(id: "#{module_id}:dependency:#{index}")
            end

          TransformResult.new(rewrite_imports(code, calls, dependencies), dependencies, nil, [], [], {})
        end

        private

        def import_calls(node)
          calls = []
          walk(node) do |child|
            if child.instance_of?(::SyntaxTree::CallNode)
              next unless child.instance_variable_get(:@receiver).nil?
              next unless child.instance_variable_get(:@message)&.value == "import"

              calls << build_import_call(child)
            elsif child.instance_of?(::SyntaxTree::Command)
              next unless child.instance_variable_get(:@message)&.value == "import"

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
            !literal
          )
        end

        def unwrap_paren(node)
          return node unless node.instance_of?(::SyntaxTree::Paren)

          statements = node.instance_variable_get(:@contents)
          body = statements&.instance_variable_get(:@body) || []
          (body.length == 1) ? body.first : node
        end

        def rewrite_imports(code, calls, dependencies)
          calls
            .zip(dependencies)
            .reverse_each
            .each_with_object(code.dup) do |(call, dependency), rewritten|
              next rewritten if call.dynamic

              location = call.location
              original = code[location.start_char...location.end_char]
              unless original.match?(IMPORT_RE)
                raise DynamicImportError, "Could not safely rewrite import at #{location.start_line}:#{location.start_column}"
              end

              rewritten[location.start_char...location.end_char] =
                "__klenod_import__(#{dependency.id.inspect})"
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
end
