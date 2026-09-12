# frozen_string_literal: true

require "language_server-protocol"

require "klenod/build/module_id"

require_relative "../../text"

module Klenod
  module LSP
    module Languages
      class Haml
        # Completes `%Component` tags from the constants bound by imports, and
        # file paths inside `import("...")` literals.
        #
        # Only the line up to the cursor is inspected, because the tag or
        # literal is usually unterminated while it is being typed.
        module Completion
          Interface = LanguageServer::Protocol::Interface
          Constant = LanguageServer::Protocol::Constant

          COMPONENT_PREFIX = /%(?<partial>[A-Z][A-Za-z0-9_]*)?\z/
          IMPORT_PREFIX = /\b(?:lazy_)?import(?:_glob)?\(\s*["'](?<partial>[^"']*)\z/
          SKIPPED_FILE = /\A\.|\.test\.rb\z/

          module_function

          def call(analysis, position, workspace)
            line_text = analysis.lines[position.line]
            return nil unless line_text

            prefix = line_text[0...position.character].to_s
            items = component_items(prefix, position, analysis, workspace) || import_items(prefix, position, analysis, workspace)
            return nil unless items

            Interface::CompletionList.new(is_incomplete: false, items: items)
          end

          def component_items(prefix, position, analysis, workspace)
            match = COMPONENT_PREFIX.match(prefix)
            return nil unless match

            partial = match[:partial].to_s
            range = replacement_range(position, partial)

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

          def import_items(prefix, position, analysis, workspace)
            match = IMPORT_PREFIX.match(prefix)
            return nil unless match

            partial = match[:partial]
            return nil if partial.match?(Klenod::Build::ModuleId::SCHEME_PATTERN)

            directory = completion_directory(partial, analysis, workspace)
            return nil unless directory

            basename_partial = partial.split("/", -1).last.to_s
            range = replacement_range(position, basename_partial)

            entries(directory).filter_map do |name, folder|
              next unless name.start_with?(basename_partial)

              label = folder ? "#{name}/" : name
              Interface::CompletionItem.new(
                label: label,
                kind: folder ? Constant::CompletionItemKind::FOLDER : Constant::CompletionItemKind::FILE,
                sort_text: "#{folder ? 0 : 1}#{name}",
                text_edit: Interface::TextEdit.new(range: range, new_text: label)
              )
            end
          end

          # Leading-slash specifiers start at the source root; everything else
          # starts next to the importing module, and both must stay inside it.
          def completion_directory(partial, analysis, workspace)
            directory_part = partial.include?("/") ? partial[0..partial.rindex("/")] : ""
            base =
              if partial.start_with?("/")
                directory_part = directory_part.delete_prefix("/")
                workspace.source_dir
              else
                importer_path = workspace.path_for_module_id(analysis.module_id)
                importer_path && File.dirname(importer_path)
              end
            return nil unless base

            directory = File.expand_path(directory_part, base)
            return nil unless directory == workspace.source_dir || directory.start_with?("#{workspace.source_dir}/")
            return nil unless File.directory?(directory)

            directory
          end

          def entries(directory)
            Dir.children(directory).sort.filter_map do |name|
              next if name.match?(SKIPPED_FILE)

              [name, File.directory?(File.join(directory, name))]
            end
          end

          def replacement_range(position, partial)
            Text::Span.new(position.line, position.character - partial.length, position.character).to_range
          end
        end
      end
    end
  end
end
