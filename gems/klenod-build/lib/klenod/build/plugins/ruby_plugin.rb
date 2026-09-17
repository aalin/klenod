# frozen_string_literal: true

require "prism"

require_relative "../plugin"
require_relative "../ruby_import_rewriter"
require_relative "../source_error"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      module RubyPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class ParseError < Klenod::Build::SourceError
          def kind
            "Ruby parse error"
          end

          private

          def location(error)
            return prism_location(error) if error.is_a?(Prism::ParseResult)
            return nil unless error.respond_to?(:lineno)

            Location.new(
              line: error.lineno,
              # SyntaxTree reports a zero-based column.
              column: error.column && error.column + 1,
              detail: error.message
            )
          end

          # Prism reports each failure as data rather than a message to scrape,
          # and phrases the first as "what is wrong; what was expected".
          def prism_location(result)
            first, *rest = result.errors
            detail, _, expected = first.message.partition("; ")

            Location.new(
              line: first.location.start_line,
              column: first.location.start_column + 1,
              detail: detail,
              hints: [expected, *rest.map(&:message)].reject(&:empty?).map(&:capitalize)
            )
          end
        end

        class Plugin < Klenod::Build::Plugin
          def transform(module_id, code, context)
            return TransformResult.identity(code) unless module_id.extname == ".rb"

            program = parse!(module_id, code)

            result =
              begin
                RubyImportRewriter
                  .new(
                    module_id: module_id,
                    kind: :ruby_import,
                    source_dir: context.source_dir,
                    profiler: context.profiler
                  )
                  .rewrite(code)
              rescue SyntaxTree::Parser::ParseError => error
                raise ParseError.new(error, source: code, module_id: module_id)
              end
            TransformResult.new(
              result.code,
              result.dependencies,
              nil,
              [],
              result.watched_patterns,
              {ruby_constants: top_level_constants(program)}
            )
          end

          # The value an importer receives: the requested constant, or Default
          # when the module defines one. Nil keeps the Exports module.
          def import_value(resolved_dependency, record, context)
            name = import_constant_name(resolved_dependency, record)
            return nil unless name

            context.mods.fetch(record.id).const_get(:Exports).const_get(name, false)
          end

          def runtime_import_value(resolved_dependency, record, _context)
            name = import_constant_name(resolved_dependency, record)
            return nil unless name

            Runtime::DefaultImport.new(name)
          end

          private

          # The rewriter only parses a file that contains an import it cannot
          # rewrite literally, so without this parse most syntax errors would
          # not surface until the module was evaluated -- and a production build
          # never evaluates application modules, so the bundle would ship
          # broken. Prism is the parser CRuby itself uses, and parsing costs
          # well under a millisecond per file. The same tree tells us which
          # constants the module exports.
          def parse!(module_id, code)
            result = Prism.parse(code)
            raise ParseError.new(result, source: code, module_id: module_id) if result.failure?

            result.value
          end

          # The constants a module defines at its top level, meaning directly
          # on its Exports module. Only static definitions count: `const_set`,
          # constants inside `if` or `begin`, `A::B = 1`, and `class ::A` are
          # not exports.
          def top_level_constants(program)
            program.statements.body.flat_map { |node| defined_constant_names(node) }.uniq
          end

          def defined_constant_names(node)
            case node
            when Prism::ConstantWriteNode
              [node.name]
            when Prism::ClassNode, Prism::ModuleNode
              node.constant_path.is_a?(Prism::ConstantReadNode) ? [node.constant_path.name] : []
            when Prism::MultiWriteNode
              [*node.lefts, *node.rights].grep(Prism::ConstantTargetNode).map(&:name)
            else
              []
            end
          end

          # Records without a constant list were not transformed by this plugin
          # and keep whatever value other plugins or the graph supply.
          def import_constant_name(resolved_dependency, record)
            constants = record.metadata[:ruby_constants]
            return nil unless constants

            name = resolved_dependency.dependency.metadata.fetch(:import_name, :Default)
            constants.include?(name) ? name : nil
          end
        end
      end
    end
  end
end
