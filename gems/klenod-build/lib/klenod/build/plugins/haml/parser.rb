# frozen_string_literal: true

require "ripper"
require "syntax_tree/haml"

module Klenod
  module Build
    module Plugins
      module Haml
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
