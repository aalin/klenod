# frozen_string_literal: true

require_relative "../diagnostics"
require_relative "../text"
require_relative "imports"
require_relative "haml/completion"

module Klenod
  module LSP
    module Languages
      # Diagnostics and navigation for Haml component modules.
      #
      # The Haml parser reports lines only, so everything here recovers
      # columns by scanning the original line text.
      class Haml
        include ImportNavigation

        COMPONENT_TAG = /%(?<name>[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)/
        BINDING = /\A\s*(?<name>[A-Z][A-Za-z0-9_]*)\s*=\s*(?:lazy_)?import\(\s*(?<quote>["'])(?<specifier>[^"']*)\k<quote>/

        def diagnostics(analysis)
          Diagnostics.for_analysis(analysis)
        end

        def completion(analysis, position, workspace)
          Completion.call(analysis, position, workspace)
        end

        # The import literal or `%Component` tag under the cursor.
        def target_at(analysis, position)
          line_text = analysis.lines[position.line]
          return nil unless line_text

          Imports.target_at(line_text, position) || component_target_at(line_text, position, analysis.lines)
        end

        # `%Details` compiles to the constant `Details`, bound by an import in
        # the leading `:ruby` filter such as `Details = import("/components/Details")`.
        def self.bindings(lines)
          lines.each_with_object({}) do |line_text, bindings|
            match = BINDING.match(line_text)
            bindings[match[:name]] ||= match[:specifier] if match
          end
        end

        private

        def component_target_at(line_text, position, lines)
          Text.each_match(line_text, position.line, COMPONENT_TAG, group: :name) do |match, span|
            next unless span.include?(position)

            constant_name = match[:name].split("::").first
            specifier = self.class.bindings(lines)[constant_name]
            return specifier && Imports::Target.new(:component, match[:name], specifier, span)
          end

          nil
        end
      end
    end
  end
end
