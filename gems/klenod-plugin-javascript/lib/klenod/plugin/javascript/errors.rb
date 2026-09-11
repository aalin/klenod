# frozen_string_literal: true

require "klenod/build/source_error"

module Klenod
  module Build
    module Plugins
      module JavaScriptPlugin
        # The native parser raises a bare SyntaxError, which is a ScriptError
        # rather than a StandardError, so it escapes every `rescue => e` in the
        # build and takes the watcher thread down with it. Wrapping it in a
        # SourceError that carries the source lets it be collected like a Haml
        # parse error and rendered in the browser error dialog.
        class ParseError < Klenod::Build::SourceError
          # "app:/pages/thing.tsx:33:9: Expected '</', got ':'"
          LOCATION = /\A(?<file>.+?):(?<line>\d+):(?<column>\d+):\s*(?<message>.*)\z/m

          def kind
            "JavaScript parse error"
          end

          private

          def location(error)
            found = LOCATION.match(error.message)
            return nil unless found

            # One-based, matching HamlPlugin::ParseError#line and the column the
            # native parser reports.
            Location.new(
              line: found[:line].to_i,
              column: found[:column].to_i,
              detail: found[:message]
            )
          end
        end
      end
    end
  end
end
