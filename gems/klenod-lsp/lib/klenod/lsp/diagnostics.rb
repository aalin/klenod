# frozen_string_literal: true

require "klenod/build/source_error"

require_relative "text"

module Klenod
  module LSP
    # Turns the errors in an Analysis into LSP diagnostics on the original
    # document. Every diagnostic is an error: Klenod has no warnings yet.
    module Diagnostics
      Interface = LanguageServer::Protocol::Interface
      Constant = LanguageServer::Protocol::Constant

      SOURCE = "klenod"
      IMPORT_CALL = /\b(?:lazy_)?import(?:_glob)?\(\s*(?<quote>["'])(?<specifier>[^"']*)\k<quote>/

      module_function

      def for_analysis(analysis)
        lines = analysis.lines
        diagnostics = []
        diagnostics << build_error(analysis, lines) if analysis.build_error
        diagnostics.concat(ruby_errors(analysis, lines))
        diagnostics.concat(resolve_errors(analysis, lines))
        diagnostics
      end

      def build_error(analysis, lines)
        error = analysis.build_error

        if error.is_a?(Klenod::Build::SourceError)
          source_error(analysis, error, lines)
        else
          diagnostic(Text.line_span(lines, 0), "#{short_class_name(error)}: #{error.message}")
        end
      end

      def source_error(analysis, error, lines)
        message = [error.kind, error.detail].compact.join(": ")
        message = "#{message}\n#{error.hints.join("\n")}" unless error.hints.empty?

        if error.module_id.to_s == analysis.module_id.to_s
          line = error.line ? error.line - 1 : 0
          diagnostic(Text.line_span(lines, line), message)
        else
          diagnostic(Text.line_span(lines, 0), "#{error.module_id}: #{message}")
        end
      end

      def ruby_errors(analysis, lines)
        source_map = analysis.source_map

        analysis.ruby_errors.map { |error|
          original_line = source_map&.find_original_line_no(error.generated_line)
          line = original_line ? original_line - 1 : 0
          diagnostic(Text.line_span(lines, line), "Generated Ruby syntax error: #{error.message}")
        }.uniq { |diagnostic| [diagnostic.range.start.line, diagnostic.message] }
      end

      def resolve_errors(analysis, lines)
        analysis.resolve_errors.map do |error|
          diagnostic(resolve_error_span(error, lines), error.message)
        end
      end

      # Resolve errors know their import's line and column, but for imports
      # outside the leading `:ruby` filter the location points into generated
      # Ruby, so the literal is looked up in the document text first.
      def resolve_error_span(error, lines)
        specifier = error.requested_specifier || error.dependency&.specifier&.to_s
        span = specifier && literal_span(specifier, lines)
        return span if span

        line = error.source_location&.line
        line = line&.between?(1, lines.length) ? line - 1 : 0
        Text.line_span(lines, line)
      end

      def literal_span(specifier, lines)
        lines.each_with_index do |line_text, index|
          Text.each_match(line_text, index, IMPORT_CALL, group: :specifier) do |match, span|
            return span if match[:specifier] == specifier
          end
        end

        nil
      end

      def diagnostic(span, message)
        Interface::Diagnostic.new(
          range: span.to_range,
          severity: Constant::DiagnosticSeverity::ERROR,
          source: SOURCE,
          message: message
        )
      end

      def short_class_name(error)
        error.class.name.to_s.split("::").last
      end
    end
  end
end
