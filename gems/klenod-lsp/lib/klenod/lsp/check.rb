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

      # Prints one `path:line:column: severity: message` entry per diagnostic
      # with paths relative to `root`, then a summary. Returns the number of
      # diagnostics.
      def self.report(results, output:, root: Dir.pwd)
        diagnostics = results.flat_map do |result|
          result.diagnostics
            .sort_by { |diagnostic| [diagnostic.range.start.line, diagnostic.range.start.character] }
            .map { |diagnostic| [display_path(result.path, root), diagnostic] }
        end

        diagnostics.each do |path, diagnostic|
          start = diagnostic.range.start
          first_line, *rest = diagnostic.message.lines(chomp: true)
          output.puts "#{path}:#{start.line + 1}:#{start.character + 1}: #{SEVERITY_NAMES.fetch(diagnostic.severity)}: #{first_line}"
          rest.each { |line| output.puts "  #{line}" }
        end

        output.puts summary(results, diagnostics.map(&:last))
        diagnostics.length
      end

      def self.summary(results, diagnostics)
        files = "#{results.length} #{(results.length == 1) ? "file" : "files"} checked"
        return "No problems found, #{files}." if diagnostics.empty?

        counts = diagnostics.group_by(&:severity).sort.map do |severity, group|
          name = SEVERITY_NAMES.fetch(severity)
          "#{group.length} #{(group.length == 1) ? name : "#{name}s"}"
        end
        "#{counts.join(", ")}, #{files}."
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
