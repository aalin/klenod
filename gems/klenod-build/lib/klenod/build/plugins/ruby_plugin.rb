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

            assert_parses!(module_id, code)

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
            TransformResult.new(result.code, result.dependencies, nil, [], result.watched_patterns, {})
          end

          private

          # The rewriter only parses a file that contains an import it cannot
          # rewrite literally, so without this check most syntax errors would
          # not surface until the module was evaluated -- and a production build
          # never evaluates application modules, so the bundle would ship
          # broken. Prism is the parser CRuby itself uses, and validating costs
          # well under a tenth of a millisecond per file.
          def assert_parses!(module_id, code)
            return if Prism.parse_success?(code)

            raise ParseError.new(Prism.parse(code), source: code, module_id: module_id)
          end
        end
      end
    end
  end
end
