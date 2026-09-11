# frozen_string_literal: true

require "json"
require "toml-rb"
require "yaml"

require_relative "../plugin"
require_relative "../source_error"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      module DataPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class Plugin < Klenod::Build::Plugin
          # A format that cannot fail to parse declares no wrapped errors, and
          # `rescue *[]` then catches nothing.
          WRAPPED_ERRORS = [].freeze

          def self.extensions(*values)
            const_set(:EXTENSIONS, values.freeze)
          end

          # Names the SourceError to raise and the library exceptions it wraps.
          def self.parse_error(error_class, *wrapped)
            const_set(:PARSE_ERROR, error_class)
            const_set(:WRAPPED_ERRORS, wrapped.freeze)
          end

          def transform(module_id, code, _context)
            return super unless self.class::EXTENSIONS.include?(module_id.extname)

            data = parse_source(code, module_id)
            TransformResult.new(module_source(data), [], nil, [], [], {data: data})
          end

          def import_value(_resolved_dependency, record, context)
            return nil unless self.class::EXTENSIONS.include?(record.id.extname)

            context.mods.fetch(record.id).const_get(:Exports)::Default
          end

          def runtime_import_value(_resolved_dependency, record, _context)
            return nil unless self.class::EXTENSIONS.include?(record.id.extname)

            record.metadata.fetch(:data)
          end

          private

          # Each format's library raises its own exception type. Wrapping them
          # here keeps every `parse` hook a one-liner and gives all four formats
          # the same report.
          def parse_source(code, module_id)
            parse(code)
          rescue *self.class::WRAPPED_ERRORS => error
            raise self.class::PARSE_ERROR.new(error, source: code, module_id: module_id)
          end

          def module_source(data)
            <<~RUBY
              Default = #{data.inspect}
            RUBY
          end
        end
      end

      module JsonPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class ParseError < Klenod::Build::SourceError
          # "expected ':' after object key, got: '2' at line 3 column 7"
          LOCATION = /\s+at line \d+ column \d+\z/

          def kind
            "JSON parse error"
          end

          private

          def location(error)
            return nil unless error.line

            # The location is rendered as the title and the caret, so drop the
            # copy the parser appends to its message.
            Location.new(
              line: error.line,
              column: error.column,
              detail: error.message.sub(LOCATION, "")
            )
          end
        end

        class Plugin < DataPlugin::Plugin
          extensions ".json"
          parse_error ParseError, JSON::ParserError

          private

          def parse(code)
            JSON.parse(code)
          end
        end
      end

      module YamlPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class ParseError < Klenod::Build::SourceError
          def kind
            "YAML parse error"
          end

          private

          def location(error)
            # Psych::DisallowedClass and friends carry no location.
            return nil unless error.is_a?(Psych::SyntaxError)

            # One-based. libyaml points at the construct it was parsing when it
            # gave up, which is not always the offending line, so `context` is
            # worth surfacing.
            Location.new(
              line: error.line,
              column: error.column,
              detail: error.problem,
              hints: [error.context&.capitalize].compact
            )
          end
        end

        class Plugin < DataPlugin::Plugin
          extensions ".yaml", ".yml"
          parse_error ParseError, Psych::Exception

          private

          def parse(code)
            YAML.safe_load(code, permitted_classes: [Date, Time, Symbol], aliases: true)
          end
        end
      end

      module TomlPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class ParseError < Klenod::Build::SourceError
          # "Failed to parse input on line 2 at offset 9\ninvalid =\n\n         ^"
          LOCATION = /\AFailed to parse input on line (?<line>\d+) at offset (?<column>\d+)/

          def kind
            "TOML parse error"
          end

          private

          def location(error)
            found = LOCATION.match(error.message)
            return nil unless found

            # toml-rb embeds its own caret diagram in the message; we render our
            # own from the line and column instead.
            Location.new(
              line: found[:line].to_i,
              # citrus reports a zero-based offset into the line.
              column: found[:column].to_i + 1,
              detail: "Could not parse TOML"
            )
          end
        end

        class Plugin < DataPlugin::Plugin
          extensions ".toml"
          parse_error ParseError, TomlRB::Error

          private

          def parse(code)
            TomlRB.parse(code)
          end
        end
      end

      module TextPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class Plugin < DataPlugin::Plugin
          extensions ".txt", ".text"

          private

          def parse(code)
            code
          end
        end
      end
    end
  end
end
