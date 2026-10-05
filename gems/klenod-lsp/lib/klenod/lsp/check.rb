# frozen_string_literal: true

require "async"
require "logger"

require_relative "documents"
require_relative "graph_index"
require_relative "languages"
require_relative "workspace"

module Klenod
  module LSP
    # Reports the language server's diagnostics for every source file at
    # once, for terminals and CI.
    #
    # The graph index collects the whole application first, as the server
    # does in the background, so cross-file diagnostics such as unknown props
    # and scoped classes are complete. Nothing is ever evaluated.
    class Check
      Constant = LanguageServer::Protocol::Constant

      SEVERITY_NAMES = {
        Constant::DiagnosticSeverity::ERROR => "error",
        Constant::DiagnosticSeverity::WARNING => "warning",
        Constant::DiagnosticSeverity::INFORMATION => "info",
        Constant::DiagnosticSeverity::HINT => "hint"
      }.freeze

      COLORS = {
        path: "\e[4m",
        location: "\e[2m",
        error: "\e[31m",
        warning: "\e[33m",
        info: "\e[1;34m",
        hint: "\e[2m",
        detail: "\e[2m",
        code: "\e[36m",
        success: "\e[1;32m"
      }.freeze
      RESET = "\e[0m"
      CODE = /`([^`\n]+)`/

      # One checked file and its diagnostics, which may be empty.
      Result = Data.define(:path, :diagnostics)

      def initialize(context:, entrypoints: [], logger: nil)
        @workspace = Workspace.new(context: context)
        @index = GraphIndex.new(
          workspace: @workspace,
          entrypoints: entrypoints,
          logger: logger || Logger.new($stderr, progname: "klenod-lsp", level: :warn)
        )
      end

      # Checks the source files below `paths`, or all of them when `paths` is
      # empty. Paths are absolute files or directories.
      def call(paths = [])
        Sync do |task|
          @index.start(task)
          @index.wait
        end

        @index.source_module_ids.filter_map do |module_id|
          path = @workspace.path_for_module_id(module_id)
          next unless selected?(path, paths)

          document = Document.new(uri: @workspace.uri_for_path(path), path: path, module_id: module_id, text: File.read(path), version: nil)
          language = Languages.for(document)
          next unless language

          Result.new(path: path, diagnostics: language.diagnostics(@workspace.analyze(module_id, document.text), @workspace, @index))
        end
      end

      # Prints the diagnostics grouped by file, like ESLint's stylish format,
      # with paths relative to `root`, then a summary:
      #
      #   src/pages/Home.haml
      #     4:3   warning  `Card` is imported but never used
      #     9:12  error    Could not resolve "./Missing"
      #
      #   1 error, 1 warning, 42 files checked.
      #
      # Columns share one width across all files, so every row lines up.
      # Returns the number of diagnostics. Colors default to on for a terminal
      # unless NO_COLOR is set.
      def self.report(results, output:, root: Dir.pwd, color: color?(output))
        paint = color ? ->(name, text) { "#{COLORS.fetch(name)}#{text}#{RESET}" } : ->(_name, text) { text }
        files = results.reject { |result| result.diagnostics.empty? }.map do |result|
          rows = result.diagnostics
            .sort_by { |diagnostic| [diagnostic.range.start.line, diagnostic.range.start.character] }
            .map do |diagnostic|
              start = diagnostic.range.start
              [start.line + 1, start.character + 1, SEVERITY_NAMES.fetch(diagnostic.severity), diagnostic.message]
            end
          [result.path, rows]
        end
        rows = files.flat_map(&:last)

        # Line numbers align right and columns left, so the colons line up.
        line_width = rows.map { |line, _, _, _| line.to_s.length }.max
        column_width = rows.map { |_, column, _, _| column.to_s.length }.max
        severity_width = rows.map { |_, _, severity, _| severity.length }.max
        indent = " " * (2 + line_width.to_i + 1 + column_width.to_i + 2 + severity_width.to_i + 2)

        files.each do |path, file_rows|
          output.puts paint.call(:path, display_path(path, root))
          file_rows.each do |line, column, severity, message|
            location = "#{line.to_s.rjust(line_width)}:#{column.to_s.ljust(column_width)}"
            first_line, *rest = message.lines(chomp: true)
            first_line = highlight(first_line) if color
            output.puts "  #{paint.call(:location, location)}  #{paint.call(severity.to_sym, severity.ljust(severity_width))}  #{first_line}"
            rest.each { |text| output.puts "#{indent}#{color ? highlight(text, COLORS.fetch(:detail)) : text}" }
          end
          output.puts
        end

        diagnostics = results.flat_map(&:diagnostics)
        output.puts summary(results, diagnostics, paint)
        diagnostics.length
      end

      def self.summary(results, diagnostics, paint = ->(_name, text) { text })
        files = "#{results.length} #{(results.length == 1) ? "file" : "files"} checked"
        return "#{paint.call(:success, "No problems found")}, #{files}." if diagnostics.empty?

        counts = diagnostics.group_by(&:severity).sort.map do |severity, group|
          name = SEVERITY_NAMES.fetch(severity)
          paint.call(name.to_sym, "#{group.length} #{(group.length == 1) ? name : "#{name}s"}")
        end
        "#{counts.join(", ")}, #{files}."
      end

      # Colors backticked names such as `Card` in place of their backticks.
      # `base` is the color of the surrounding text, restored after each name.
      def self.highlight(text, base = nil)
        highlighted = text.gsub(CODE) { "#{COLORS.fetch(:code)}#{Regexp.last_match(1)}#{RESET}#{base}" }
        base ? "#{base}#{highlighted}#{RESET}" : highlighted
      end

      def self.color?(output, env = ENV)
        return false if env.key?("NO_COLOR")

        output.respond_to?(:tty?) && output.tty?
      end

      def self.display_path(path, root)
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        relative.start_with?("../") ? path : relative
      end

      private

      def selected?(path, paths)
        return true if paths.empty?

        paths.any? { |selected| path == selected || path.start_with?("#{selected}/") }
      end
    end
  end
end
