# frozen_string_literal: true

require "klenod/build/source_excerpt"

module Klenod
  module Build
    module Plugins
      module JavaScriptPlugin
        # The native parser raises a bare SyntaxError, which is a ScriptError
        # rather than a StandardError, so it escapes every `rescue => e` in the
        # build and takes the watcher thread down with it. Wrapping it in a
        # StandardError that carries the source lets it be collected like a Haml
        # parse error and rendered in the browser error dialog.
        class ParseError < StandardError
          # "app:/pages/thing.tsx:33:9: Expected '</', got ':'"
          LOCATION = /\A(?<file>.+?):(?<line>\d+):(?<column>\d+):\s*(?<message>.*)\z/m

          attr_reader :module_id, :source, :line, :column, :cause

          def initialize(error, source:, module_id:)
            @cause = error
            @module_id = module_id
            @source = source

            location = LOCATION.match(error.message)
            # One-based, matching HamlPlugin::ParseError#line and the column
            # the native parser reports.
            @line = location && location[:line].to_i
            @column = location && location[:column].to_i

            super(
              SourceExcerpt.message(
                module_id:,
                line: @line,
                kind: "JavaScript parse error",
                source:,
                message: location ? location[:message] : error.message
              )
            )

            set_backtrace(backtrace_for(error))
          end

          private

          # The browser dialog highlights source lines by matching backtrace
          # frames against the filename, and a native parse error has no Ruby
          # frame pointing at the module, so synthesize one.
          def backtrace_for(error)
            frames = Array(error.backtrace)
            return frames unless line

            ["#{module_id}:#{line}:#{column}", *frames]
          end
        end
      end
    end
  end
end
