# frozen_string_literal: true

require "language_server-protocol"

require "klenod/build/module_id"

require_relative "../text"

module Klenod
  module LSP
    module Languages
      # Everything shared by languages whose modules import through
      # `import("...")` literals: finding the literal under the cursor or all
      # literals in a document, resolving it, summarizing the target, and
      # completing the path being typed.
      module Imports
        Interface = LanguageServer::Protocol::Interface
        Constant = LanguageServer::Protocol::Constant

        IMPORT_CALL = /\b(?<call>(?:lazy_)?import(?:_glob)?)\(\s*(?<quote>["'])(?<specifier>[^"']*)\k<quote>/
        IMPORT_PREFIX = /\b(?:lazy_)?import(?:_glob)?\(\s*["'](?<partial>[^"']*)\z/
        PROP_TOKEN = /\$(?<name>[a-z]\w*|\*)/
        SKIPPED_FILE = /\A\.|\.test\.rb\z/

        # Something in a document that names another module.
        Target = Data.define(:kind, :name, :specifier, :span)

        module_function

        def target_at(line_text, position)
          each_target(line_text, position.line) do |target|
            return target if target.span.include?(position)
          end

          nil
        end

        # Import literals on one line; glob imports name many modules and are
        # skipped.
        def each_target(line_text, line_index)
          Text.each_match(line_text, line_index, IMPORT_CALL, group: :specifier) do |match, span|
            next if match[:call] == "import_glob"

            yield Target.new(:import, match[:specifier], match[:specifier], span)
          end
        end

        def resolve(target, analysis, workspace)
          analysis.resolved_module_id_for(target.specifier) || workspace.resolve(target.specifier, importer_id: analysis.module_id)
        end

        def location(module_id, workspace)
          uri = workspace.uri_for_module_id(module_id)
          uri && Interface::Location.new(uri: uri, range: Text.zero_range)
        end

        # Markdown summary: module id, path, and the props a Haml component
        # reads through the configured `$name` mapping.
        def hover(target, module_id, workspace)
          path = workspace.path_for_module_id(module_id)
          lines = ["**#{target.name}** · `#{module_id}`"]
          lines << "`#{path.delete_prefix("#{workspace.source_dir}/")}`" if path

          props = props_for(path, workspace)
          lines << "Props: #{props.map { |prop| "`#{prop}`" }.join(", ")}" unless props.empty?

          Interface::Hover.new(
            contents: Interface::MarkupContent.new(kind: Constant::MarkupKind::MARKDOWN, value: lines.join("\n\n")),
            range: target.span.to_range
          )
        end

        # Only lowercase `$name` globals are rewritten to prop reads, and only
        # when the Haml plugin maps global variables at all.
        def props_for(path, workspace)
          return [] unless path && File.extname(path) == ".haml"
          return [] unless workspace.haml_variables[:global]

          File.read(path).scan(PROP_TOKEN).flatten.uniq.sort.map { |name| "$#{name}" }
        rescue SystemCallError
          []
        end

        # Completion items for the path being typed inside an import literal,
        # or nil when the line prefix is not inside one.
        def completion_items(prefix, position, analysis, workspace)
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

      # Request handlers shared by languages that navigate through imports.
      # Including classes define `target_at(analysis, position)`.
      module ImportNavigation
        def definition(analysis, position, workspace)
          target = target_at(analysis, position)
          module_id = target && Imports.resolve(target, analysis, workspace)
          module_id && Imports.location(module_id, workspace)
        end

        def hover(analysis, position, workspace)
          target = target_at(analysis, position)
          module_id = target && Imports.resolve(target, analysis, workspace)
          module_id && Imports.hover(target, module_id, workspace)
        end
      end
    end
  end
end
