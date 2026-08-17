# frozen_string_literal: true

module Klenod
  module Plugin
    module JavaScript
      ImportRecord = Data.define(:specifier, :kind, :start_offset, :end_offset, :loc)

      module Parser
        module_function

        def native?
          !native_parser.nil?
        end

        def parse(source, filename:)
          native_records = native_parser&.parse_native(source, filename)
          return native_records.map { native_import_record(it) } if native_records

          scanner = FallbackScanner.new(source, filename)
          scanner.imports
        end

        def native_parser
          @native_parser =
            if defined?(@native_parser)
              @native_parser
            else
              begin
                require "klenod/plugin/javascript/native"
                Klenod::Plugin::JavaScript::Native
              rescue LoadError
                nil
              end
            end
        end

        def native_import_record(record)
          ImportRecord.new(
            record.fetch("specifier"),
            record.fetch("kind").to_sym,
            record.fetch("start_offset"),
            record.fetch("end_offset"),
            record.fetch("loc")
          )
        end

        class FallbackScanner
          STATIC_IMPORT_PATTERN =
            /
              \bimport
              (?:\s+type)?
              (?:
                \s* (?<side_effect>["'][^"']+["'])
                |
                (?<clause>[\s\S]*?) \s+ from \s+ (?<from>["'][^"']+["'])
              )
            /x
          EXPORT_FROM_PATTERN = /\bexport\b[\s\S]*?\bfrom\s+(?<from>["'][^"']+["'])/
          DYNAMIC_IMPORT_PATTERN = /\bimport\s*\(\s*(?<from>["'][^"']+["'])\s*\)/

          def initialize(source, filename)
            @source = source
            @filename = filename
          end

          def imports
            records = []
            scan_regex(STATIC_IMPORT_PATTERN, :javascript_import, records) { |match| match[:side_effect] || match[:from] }
            scan_regex(EXPORT_FROM_PATTERN, :javascript_export, records) { |match| match[:from] }
            scan_regex(DYNAMIC_IMPORT_PATTERN, :javascript_dynamic_import, records) { |match| match[:from] }
            records.sort_by(&:start_offset)
          end

          private

          def scan_regex(pattern, kind, records)
            @source.to_enum(:scan, pattern).each do
              match = Regexp.last_match
              next if inside_comment_or_string?(match.begin(0))

              literal = yield(match)
              start_offset = @source.index(literal, match.begin(0)) + 1
              end_offset = start_offset + literal.length - 2
              records << ImportRecord.new(literal[1...-1], kind, start_offset, end_offset, loc(start_offset))
            end
          end

          def inside_comment_or_string?(offset)
            state = :code
            quote = nil
            escaped = false
            index = 0

            while index < offset
              char = @source[index]
              next_char = @source[index + 1]

              case state
              when :code
                if char == "/" && next_char == "/"
                  state = :line_comment
                  index += 1
                elsif char == "/" && next_char == "*"
                  state = :block_comment
                  index += 1
                elsif char == "\"" || char == "'" || char == "`"
                  quote = char
                  escaped = false
                  state = :string
                end
              when :line_comment
                state = :code if char == "\n"
              when :block_comment
                if char == "*" && next_char == "/"
                  state = :code
                  index += 1
                end
              when :string
                if escaped
                  escaped = false
                elsif char == "\\"
                  escaped = true
                elsif char == quote
                  state = :code
                end
              end

              index += 1
            end

            state != :code
          end

          def loc(offset)
            prefix = @source.byteslice(0, offset)
            line = prefix.count("\n") + 1
            column = offset - (prefix.rindex("\n") || -1)
            "#{@filename}:#{line}:#{column}"
          end
        end
      end
    end
  end
end
