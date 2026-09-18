# frozen_string_literal: true

module Klenod
  module LSP
    module Languages
      class Haml
        # Detects iterator blocks whose Haml bodies are either discarded or
        # whose result is not the rendered collection. Haml's parser retains
        # the body as children of the script node, which avoids guessing from
        # indentation or warning about ordinary Ruby source in a filter.
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
              next unless node.children.any?
              next unless [:script, :silent_script].include?(node.type)

              match = ITERATOR.match(node.value.fetch(:text))
              next unless match

              misuse = (node.type == :script && match[:method] == "each") || (node.type == :silent_script && match[:method] == "map")
              next unless misuse

              diagnostics << diagnostic_for(node, match, analysis.lines)
            end

            diagnostics
          rescue Klenod::Build::Plugins::HamlPlugin::ParseError
            []
          end

          def diagnostic_for(node, match, lines)
            line = node.line - 1
            line_text = lines.fetch(line, "")
            method_start = line_text.index(".#{match[:method]}") || 0
            span = Text::Span.new(line, method_start, method_start + match[:method].length + 1)

            message = if node.type == :script
              "`= ...each do` returns the original collection, not the rendered Haml children; use `map` instead"
            else
              "`- ...map do` discards the rendered Haml children; use `=` instead"
            end

            Diagnostics.warning(span, message)
          end
        end
      end
    end
  end
end
