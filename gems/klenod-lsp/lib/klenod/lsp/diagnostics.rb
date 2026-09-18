# frozen_string_literal: true

require "klenod/build/source_error"

require_relative "languages/syntax"
require_relative "text"

module Klenod
  module LSP
    # Turns the errors in an Analysis into LSP diagnostics on the original
    # document.
    module Diagnostics
      Interface = LanguageServer::Protocol::Interface
      Constant = LanguageServer::Protocol::Constant

      SOURCE = "klenod"

      module_function

      def for_analysis(analysis, syntax: Languages::Syntax::Ruby)
        lines = analysis.lines
        diagnostics = []
        diagnostics << build_error(analysis, lines) if analysis.build_error
        diagnostics.concat(ruby_errors(analysis, lines))
        diagnostics.concat(resolve_errors(analysis, lines, syntax))
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

      # A failure the graph index recorded while collecting this module that
      # analysis alone cannot see, such as a named import of a constant the
      # target does not define: analysis only transforms and resolves, it never
      # collects the target's record. The index refreshes on save, so the
      # diagnostic is only shown while the document still contains the import
      # it refers to.
      def index_failure(analysis, index, syntax: Languages::Syntax::Ruby)
        error = index&.failed&.[](analysis.module_id.to_s)
        return [] unless error.is_a?(Klenod::Build::MissingExportError)
        return [] unless error.module_id.to_s == analysis.module_id.to_s

        lines = analysis.lines
        report = error.cause
        span = literal_spans(report.dependency.specifier.to_s, lines, syntax: syntax).find do |candidate|
          named_import_span?(candidate, report.name, lines)
        end
        return [] unless span

        message = "#{error.kind}: #{error.detail}"
        message = "#{message}\n#{error.hints.join("\n")}" unless error.hints.empty?
        [diagnostic(span, message)]
      end

      def resolve_errors(analysis, lines, syntax)
        analysis.resolve_errors.map do |error|
          diagnostic(resolve_error_span(error, lines, syntax), error.message)
        end
      end

      # Resolve errors know their import's line and column, but for imports
      # outside the leading `:ruby` filter the location points into generated
      # Ruby, so the literal is looked up in the document text first.
      def resolve_error_span(error, lines, syntax = Languages::Syntax::Ruby)
        specifier = error.requested_specifier || error.dependency&.specifier&.to_s
        span = specifier && literal_span(specifier, lines, syntax: syntax)
        return span if span

        line = error.source_location&.line
        line = line&.between?(1, lines.length) ? line - 1 : 0
        Text.line_span(lines, line)
      end

      def literal_span(specifier, lines, syntax: Languages::Syntax::Ruby)
        literal_spans(specifier, lines, syntax: syntax).first
      end

      # Every occurrence of a specifier; stylesheets repeat one across
      # `@import` and `composes`.
      def literal_spans(specifier, lines, syntax: Languages::Syntax::Ruby)
        spans = []
        lines.each_with_index do |line_text, index|
          syntax.each_literal(line_text, index) do |literal|
            spans << literal.span if literal.specifier == specifier
          end
        end
        spans
      end

      # The same module can be imported more than once with different names.
      # Match the name immediately following this literal rather than selecting
      # the first matching specifier and inspecting its whole line.
      def named_import_span?(span, name, lines)
        suffix = lines[span.start.line].to_s[span.end.character..]
        suffix&.match?(%r{\A["']\s*,\s*:#{Regexp.escape(name.to_s)}(?=\s*\))})
      end

      def diagnostic(span, message)
        diagnostic_with_severity(span, message, Constant::DiagnosticSeverity::ERROR)
      end

      def warning(span, message)
        diagnostic_with_severity(span, message, Constant::DiagnosticSeverity::WARNING)
      end

      def diagnostic_with_severity(span, message, severity)
        Interface::Diagnostic.new(
          range: span.to_range,
          severity: severity,
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
