# frozen_string_literal: true

require "ripper"
require "syntax_tree/haml"

module Klenod
  module Build
    module Plugins
      module HamlPlugin
        def self.parse_haml(source, module_id: nil)
          parser = ParserWithMetadata.new({})
          parser.call(source)
        rescue ::Haml::SyntaxError => error
          raise ParseError.new(error, source: source, module_id: module_id)
        end

        class ParserWithMetadata < ::Haml::Parser
          def initialize(...)
            @tag_metadata_by_line = Hash.new { |hash, key| hash[key] = [] }
            super
          end

          def call(source)
            root = super
            annotate_tag_nodes(root)
            root
          end

          private

          def parse_tag(text)
            result = super
            _, shorthand_attributes, attribute_hashes = result
            @tag_metadata_by_line[@line.index + 1] << class_metadata(shorthand_attributes, attribute_hashes)
            result
          end

          # Haml's parenthesized-attribute parser accepts only a bare variable
          # after `=`. For example, it reads `video_id=video.id` as the value
          # `video` plus a `.id` class. Extend that form to ordinary Ruby
          # member and index expressions while leaving all other attributes on
          # Haml's native parsing path.
          #
          # Haml also continues a parenthesized list onto following lines only
          # after the first attribute, so `%a(` followed by a line break is an
          # invalid attribute list. Join the lines of an unclosed list first so
          # both forms work across lines.
          def parse_new_attributes(text)
            joined_lines = 0
            until (close_index = attribute_list_close_index(text)) || @next_line.eod?
              text = "#{text} #{@next_line.text}"
              joined_lines += 1
              next_line
            end

            pairs = close_index && extended_attribute_pairs(text[1...close_index])
            rest = close_index && text[(close_index + 1)..]
            unless pairs&.any? { |_name, value| value.match?(/[.\[]/) }
              attributes, rest, last_line = super
              return [attributes, rest, last_line + joined_lines]
            end

            dynamic = pairs.reduce("{") { |source, (name, value)| "#{source}#{::Haml::Util.inspect_obj(name)} => #{value}," } << "}"
            [[{}, dynamic], rest, @line.index + 1 + joined_lines]
          end

          def annotate_tag_nodes(root)
            queue = root.children.dup
            until queue.empty?
              node = queue.shift
              if node.type == :tag
                metadata = @tag_metadata_by_line.fetch(node.line, []).shift
                node.value[:klenod_class_metadata] = metadata if metadata
              end
              queue.concat(node.children)
            end
          end

          def class_metadata(shorthand_attributes, attribute_hashes)
            shorthand = ::Haml::Parser.parse_class_and_id(shorthand_attributes).fetch("class", "").split
            literal = []

            if (new_attributes = attribute_hashes[:new])
              literal.concat(Array(new_attributes.fetch(0)["class"]).flat_map { it.to_s.split })
            end

            if (old_attributes = attribute_hashes[:old])
              literal.concat(literal_class_names_from_old_attributes(old_attributes))
            end

            {shorthand: shorthand, literal: literal}
          end

          def extended_attribute_pairs(source)
            pairs = []
            index = 0

            loop do
              index += 1 while source[index]&.match?(/\s/)
              break if index >= source.length

              name = source[index..].match(/\A[-:@#\w.]+/)&.to_s
              return nil unless name

              index += name.length
              index += 1 while source[index]&.match?(/\s/)
              unless source[index] == "="
                pairs << [name, "true"]
                next
              end

              index += 1
              index += 1 while source[index]&.match?(/\s/)
              value_start = index
              depth = 0
              quote = nil
              escaped = false

              while index < source.length
                character = source[index]
                if quote
                  if escaped
                    escaped = false
                  elsif character == "\\"
                    escaped = true
                  elsif character == quote
                    quote = nil
                  end
                else
                  case character
                  when "'", '"' then quote = character
                  when "(", "[", "{" then depth += 1
                  when ")", "]", "}" then depth -= 1
                  when " ", "\t"
                    break if depth.zero? && attribute_boundary?(source[index..])
                  end
                end
                index += 1
              end

              value = source[value_start...index].strip
              return nil if value.empty? || depth.negative? || quote || !Ripper.sexp(value)

              pairs << [name, value]
            end

            pairs
          end

          # Returns the index of the `)` that closes the list opened at index 0,
          # ignoring brackets inside quoted values.
          def attribute_list_close_index(source)
            depth = 0
            quote = nil
            escaped = false

            source.each_char.with_index do |character, index|
              if quote
                if escaped
                  escaped = false
                elsif character == "\\"
                  escaped = true
                elsif character == quote
                  quote = nil
                end
              else
                case character
                when "'", '"' then quote = character
                when "(", "[", "{" then depth += 1
                when ")", "]", "}"
                  depth -= 1
                  return index if depth.zero?
                end
              end
            end

            nil
          end

          def attribute_boundary?(remaining_source)
            attribute_sequence?(remaining_source)
          end

          def attribute_sequence?(source)
            source = source.lstrip
            name = source.match(/\A[-:@#\w.]*\w[-:@#\w.]*/)&.to_s
            return false unless name
            return false if %w[true false nil].include?(name)

            rest = source[name.length..]
            return true if rest.empty? || rest.lstrip.start_with?("=")
            return false unless rest.start_with?(" ", "\t")

            attribute_sequence?(rest)
          end

          def literal_class_names_from_old_attributes(source)
            parsed = ::Haml::AttributeParser.parse(source)
            return [] unless parsed&.key?("class")

            value = static_string_literal_value(parsed.fetch("class"))
            value ? value.split : []
          end

          def static_string_literal_value(source)
            case Ripper.sexp(source)
            in [:program, [[:string_literal, [:string_content, [:@tstring_content, String => value, _location]]]]]
              value
            else
              nil
            end
          end
        end
      end
    end
  end
end
