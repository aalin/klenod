# frozen_string_literal: true

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

        # Raised when a .rb file containing an import cannot be parsed well
        # enough to rewrite it. A file with no import is never parsed at build
        # time, so its syntax error surfaces later as an
        # EvaluationSyntaxError instead.
        class ParseError < Klenod::Build::SourceError
          def kind
            "Ruby parse error"
          end

          private

          def location(error)
            return nil unless error.respond_to?(:lineno)

            Location.new(
              line: error.lineno,
              # SyntaxTree reports a zero-based column.
              column: error.column && error.column + 1,
              detail: error.message
            )
          end
        end

        class Plugin < Klenod::Build::Plugin
          def transform(module_id, code, context)
            return TransformResult.identity(code) unless module_id.extname == ".rb"

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
        end
      end
    end
  end
end
