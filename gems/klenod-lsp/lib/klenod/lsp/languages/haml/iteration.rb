# frozen_string_literal: true

module Klenod
  module LSP
    module Languages
      class Haml
        # Detects scripts whose nested Haml will not produce output. Haml's
        # parser retains the body as children of the script node, which avoids
        # guessing from indentation or warning about ordinary Ruby source in
        # a filter.
        module Iteration
          module_function

          ITERATOR = /\.(?<method>each|map)\b(?:\s*\([^\n]*\))?\s+do\b/

          def diagnostics(analysis)
            root = Klenod::Build::Plugins::HamlPlugin.parse_haml(analysis.source, module_id: analysis.module_id)
            nodes = root.children.dup
            diagnostics = []

            until nodes.empty?
              node = nodes.shift
              nodes.concat(node.children)
              case node.type
              when :script
                match = ITERATOR.match(node.value.fetch(:text))
                diagnostics << each_diagnostic(node, match, analysis.lines) if match&.[](:method) == "each" && rendered_content?(node)
              when :silent_script
                diagnostics << silent_script_diagnostic(node, analysis.lines) if rendered_content?(node)
              end
            end

            diagnostics
          rescue Klenod::Build::Plugins::HamlPlugin::ParseError
            []
          end

          def rendered_content?(node)
            node.children.any? do |child|
              [:plain, :script, :tag].include?(child.type) || (child.type == :filter && child.value.fetch(:name) != "ruby") || rendered_content?(child)
            end
          end

          def each_diagnostic(node, match, lines)
            line = node.line - 1
            line_text = lines.fetch(line, "")
            method_start = line_text.index(".#{match[:method]}") || 0
            span = Text::Span.new(line, method_start, method_start + match[:method].length + 1)

            Diagnostics.warning(span, "`= ...each do` returns the original collection, not the rendered Haml children; use `map` instead")
          end

          def silent_script_diagnostic(node, lines)
            line = node.line - 1
            line_text = lines.fetch(line, "")
            start_character = line_text.index("-") || 0
            span = Text::Span.new(line, start_character, start_character + 1)

            Diagnostics.warning(span, "A silent `-` script discards its nested Haml content; use `=` when it should render")
          end
        end
      end
    end
  end
end
