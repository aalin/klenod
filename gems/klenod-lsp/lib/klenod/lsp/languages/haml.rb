# frozen_string_literal: true

require_relative "../diagnostics"
require_relative "../symbols"
require_relative "../text"
require_relative "imports"
require_relative "haml/classes"
require_relative "haml/completion"
require_relative "haml/rename"

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

        def diagnostics(analysis, workspace = nil, index = nil)
          diagnostics = Diagnostics.for_analysis(analysis)
          diagnostics.concat(Classes.diagnostics(analysis, workspace, index)) if workspace && index
          diagnostics
        end

        def completion(analysis, position, workspace, index = nil)
          Completion.call(analysis, position, workspace, index)
        end

        def definition(analysis, position, workspace, index = nil)
          occurrence = index && Classes.occurrence_at(analysis.lines, position)
          return Classes.definition(occurrence, analysis, workspace, index) if occurrence

          super(analysis, position, workspace)
        end

        def hover(analysis, position, workspace, index = nil)
          occurrence = index && Classes.occurrence_at(analysis.lines, position)
          return Classes.hover(occurrence, analysis, workspace, index) if occurrence

          super(analysis, position, workspace)
        end

        def document_symbols(analysis)
          Symbols.haml_document_symbols(analysis.source)
        end

        def rename_spans(analysis, name)
          Rename.spans(analysis.source, name)
        end

        # The import literal or `%Component` tag under the cursor.
        def target_at(analysis, position)
          line_text = analysis.lines[position.line]
          return nil unless line_text

          Imports.target_at(line_text, position, syntax: syntax) || component_target_at(line_text, position, analysis.lines)
        end

        # `%Details` compiles to the constant `Details`, bound by an import in
        # the leading `:ruby` filter such as `Details = import("/components/Details")`.
        def self.bindings(lines)
          Imports.bindings(lines)
        end

        private

        def component_target_at(line_text, position, lines)
          Text.each_match(line_text, position.line, COMPONENT_TAG, group: :name) do |match, span|
            next unless span.include?(position)

            constant_name = match[:name].split("::").first
            specifier = self.class.bindings(lines)[constant_name]
            return specifier && Imports::Target.new(kind: :component, name: match[:name], specifier: specifier, span: span)
          end

          nil
        end
      end
    end
  end
end
