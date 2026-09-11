# frozen_string_literal: true

require "klenod/build/source_error"

module Klenod
  module Build
    module Plugins
      module CSSPlugin
        # The native extension looks this class up by name and raises it with
        # only a message, so it has to tolerate being constructed that way. The
        # plugin catches that bare error and re-raises it with the source and
        # module attached, which is what fills in the excerpt.
        class ParseError < Klenod::Build::SourceError
          # "Unexpected token Colon at app:/styles.css:11:5"
          LOCATION = /\A(?<message>.*)\s+at\s+(?<file>.+):(?<line>\d+):(?<column>\d+)\s*\z/m

          def initialize(error, source: nil, module_id: nil)
            super
          end

          def kind
            "CSS parse error"
          end

          private

          def location(error)
            found = LOCATION.match(message_for(error))
            return nil unless found

            Location.new(
              # lightningcss reports a zero-based line and a one-based column.
              line: found[:line].to_i + 1,
              column: found[:column].to_i,
              detail: found[:message]
            )
          end
        end
      end
    end
  end
end
