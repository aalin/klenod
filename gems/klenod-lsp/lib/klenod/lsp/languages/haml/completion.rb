# frozen_string_literal: true

require "language_server-protocol"

require_relative "../imports"
require_relative "classes"

module Klenod
  module LSP
    module Languages
      class Haml
        # Completes `%Component` tags from the constants bound by imports, and
        # defers to the shared import path completion inside `import("...")`.
        #
        # Only the line up to the cursor is inspected, because the tag or
        # literal is usually unterminated while it is being typed.
        module Completion
          Interface = LanguageServer::Protocol::Interface
          Constant = LanguageServer::Protocol::Constant

          COMPONENT_PREFIX = /%(?<partial>[A-Z][A-Za-z0-9_]*)?\z/

          module_function

          def call(analysis, position, workspace, index = nil)
            line_text = analysis.lines[position.line]
            return nil unless line_text

            prefix = line_text[0...position.character].to_s
            items = component_items(prefix, position, analysis, workspace) || Imports.completion_items(prefix, position, analysis, workspace)
            items ||= Classes.completion_items(prefix, position, analysis, workspace, index) if index
            return nil unless items

            Interface::CompletionList.new(is_incomplete: false, items: items)
          end

          def component_items(prefix, position, analysis, workspace)
            match = COMPONENT_PREFIX.match(prefix)
            return nil unless match

            partial = match[:partial].to_s
            range = Imports.replacement_range(position, partial)

            Haml.bindings(analysis.lines).filter_map do |name, specifier|
              next unless name.start_with?(partial)

              module_id = analysis.resolved_module_id_for(specifier) || workspace.resolve(specifier, importer_id: analysis.module_id)
              Interface::CompletionItem.new(
                label: name,
                kind: Constant::CompletionItemKind::CLASS,
                detail: module_id&.to_s || specifier,
                text_edit: Interface::TextEdit.new(range: range, new_text: name)
              )
            end
          end
        end
      end
    end
  end
end
