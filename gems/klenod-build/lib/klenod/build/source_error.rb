# frozen_string_literal: true

require_relative "errors"
require_relative "source_excerpt"

module Klenod
  module Build
    # Base class for a build failure attributable to one source file.
    #
    # Plugins parse very different formats with very different libraries, but the
    # report a developer needs is the same every time: which file, which line and
    # column, what went wrong, and what to try next. A subclass supplies `kind`
    # and a `location` that unpacks its library's exception. Everything else --
    # the message layout, the source excerpt, the synthesized backtrace frame --
    # is shared, so every format renders identically in the terminal and in the
    # browser error dialog.
    #
    # Being a StandardError matters: a bare Ruby SyntaxError is a ScriptError and
    # escapes every `rescue => e` in the build, taking the watcher thread down
    # with it.
    class SourceError < Error
      # `hints` is free-form advice, one entry per line, e.g.
      # "Did you mean hero.jpeg?".
      Location = Data.define(:line, :column, :detail, :hints) do
        def initialize(line: nil, column: nil, detail: nil, hints: []) = super
      end

      attr_reader :module_id, :source, :line, :column, :cause, :detail, :hints

      def initialize(error, source:, module_id:)
        @cause = error
        @module_id = module_id
        @source = source

        found = location_for(error)
        @line = found.line
        @column = found.column
        @detail = found.detail || message_for(error)
        @hints = Array(found.hints).map(&:to_s).reject(&:empty?).freeze

        super(
          SourceExcerpt.message(
            module_id:,
            line: @line,
            column: @column,
            kind:,
            source:,
            message: @detail,
            hints: @hints
          )
        )

        set_backtrace(backtrace_for(error))
      end

      # "JavaScript parse error". Used as the label in the browser error dialog,
      # so it names the format rather than the plugin.
      def kind
        "Parse error"
      end

      private

      # Re-wrapping is idempotent: a plugin that catches its own SourceError to
      # attach the source keeps the location the first construction worked out.
      def location_for(error)
        return location(error) || Location.new unless error.is_a?(SourceError)

        Location.new(line: error.line, column: error.column, detail: error.detail, hints: error.hints)
      end

      # Subclasses override to pull line, column, detail and hints out of the
      # exception their parsing library raised. Returning nil keeps the wrapped
      # message as the detail and renders no excerpt.
      def location(_error)
        nil
      end

      # A native extension can raise with a bare message rather than an
      # exception, so do not assume #message exists.
      def message_for(error)
        error.respond_to?(:message) ? error.message : error.to_s
      end

      # The browser dialog highlights source lines by matching backtrace frames
      # against the filename. A native parser, or one that raises while
      # evaluating generated source, leaves no Ruby frame pointing at the
      # module, so synthesize one.
      def backtrace_for(error)
        frames = error.respond_to?(:backtrace) ? Array(error.backtrace) : []
        return frames unless line

        ["#{module_id}:#{[line, column].compact.join(":")}", *frames]
      end
    end

    # A module whose Ruby fails to parse when it is evaluated.
    #
    # Most .rb files never reach the build-time parser: RubyImportRewriter only
    # parses a file that contains an import, so the syntax error first surfaces
    # at `Runtime::Mod` evaluation as a bare SyntaxError -- a ScriptError, which
    # escapes every `rescue => e` in the build. Generated Ruby from another
    # format fails here too, in which case the excerpt shows the generated
    # source.
    class EvaluationSyntaxError < SourceError
      # "app:/x.rb:3: syntax error found"
      HEADER = /\A(?<file>.+?):(?<line>\d+): (?<detail>.+?)$/
      # "    | ^~~ unexpected 'end'; expected a `)` to close the arguments"
      CARET = /^ *\| (?<pad> *)\^+~* *(?<message>.*)$/

      def kind
        "Ruby syntax error"
      end

      private

      # Prism renders its own excerpt into the message. We re-render it from the
      # line and column, and keep the explanation it prints beside the caret.
      def location(error)
        header = HEADER.match(error.message)
        return nil unless header

        caret = CARET.match(error.message)
        detail, _, hint = (caret ? caret[:message] : header[:detail]).partition("; ")

        Location.new(
          line: header[:line].to_i,
          column: caret && caret[:pad].length + 1,
          detail: detail,
          hints: [hint.empty? ? nil : hint.capitalize].compact
        )
      end
    end
  end
end
