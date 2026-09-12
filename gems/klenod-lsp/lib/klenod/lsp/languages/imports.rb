# frozen_string_literal: true

require "language_server-protocol"

require "klenod/build/module_id"

require_relative "../diagnostics"
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
        BINDING = /\A\s*(?<name>[A-Z][A-Za-z0-9_]*)\s*=\s*(?:lazy_)?import\(\s*(?<quote>["'])(?<specifier>[^"']*)\k<quote>/
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

          binding_target_at(line_text, position)
        end

        # The constant a module is bound to, as in `Card = import("./Card")`.
        def binding_target_at(line_text, position)
          Text.each_match(line_text, position.line, BINDING, group: :name) do |match, span|
            return Target.new(:binding, match[:name], match[:specifier], span) if span.include?(position)
          end

          nil
        end

        # Constant names bound to imports in a document, keyed by name.
        def bindings(lines)
          lines.each_with_object({}) do |line_text, bindings|
            match = BINDING.match(line_text)
            bindings[match[:name]] ||= match[:specifier] if match
          end
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

        STRING_LITERAL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/

        def constant_pattern(name)
          /(?<![\w:@$])(?<name>#{Regexp.escape(name)})(?!\w)/
        end

        # Whole-word occurrences of a constant in Ruby text, ignoring the
        # contents of string literals.
        def constant_spans(text, line_index, name)
          blanked = text.gsub(STRING_LITERAL) { |literal| " " * literal.length }
          spans = []
          Text.each_match(blanked, line_index, constant_pattern(name), group: :name) { |_match, span| spans << span }
          spans
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

        # References to the module under the cursor, or to the document's own
        # module when the cursor is on nothing in particular.
        def references(analysis, position, workspace, index, include_declaration: false)
          target = target_at(analysis, position)
          module_id = target ? Imports.resolve(target, analysis, workspace) : analysis.module_id
          return [] unless module_id

          index.ensure_collected(module_id) if workspace.path_for_module_id(module_id)
          reference_locations(module_id, index, workspace, include_declaration: include_declaration)
        end

        # One lens on the first line with the number of places that import
        # or render this module. Clients that know VS Code's command show
        # the list on click; others show the count.
        def code_lenses(analysis, workspace, index)
          locations = reference_locations(analysis.module_id, index, workspace)
          uri = workspace.uri_for_module_id(analysis.module_id)
          return [] unless uri

          title =
            case locations.length
            when 0 then "No references"
            when 1 then "1 reference"
            else "#{locations.length} references"
            end
          command = Imports::Interface::Command.new(
            title: title,
            command: "editor.action.showReferences",
            arguments: [uri, Imports::Interface::Position.new(line: 0, character: 0), locations]
          )

          range = Text.line_span(analysis.lines, 0).to_range
          route_lenses = workspace.routes.descriptions(analysis.module_id).map do |description|
            Imports::Interface::CodeLens.new(range: range, command: Imports::Interface::Command.new(title: description, command: ""))
          end

          [*route_lenses, Imports::Interface::CodeLens.new(range: range, command: command)]
        end

        CONSTANT_NAME = /\A[A-Z][A-Za-z0-9_]*\z/

        class InvalidRename < StandardError; end

        # The constant a module is bound to can be renamed within its file:
        # the cursor must be on the binding or on a component tag.
        def prepare_rename(analysis, position)
          target = rename_target(analysis, position)
          return nil unless target

          {range: target.span.to_range, placeholder: target.name.split("::").first}
        end

        def rename(analysis, position, new_name, workspace)
          raise InvalidRename, "#{new_name.inspect} is not a constant name" unless new_name.match?(CONSTANT_NAME)

          target = rename_target(analysis, position)
          uri = target && workspace.uri_for_module_id(analysis.module_id)
          return nil unless uri

          name = target.name.split("::").first
          edits = rename_spans(analysis, name).map { |span| Imports::Interface::TextEdit.new(range: span.to_range, new_text: new_name) }
          return nil if edits.empty?

          Imports::Interface::WorkspaceEdit.new(changes: {uri => edits})
        end

        # Whole-word occurrences of the constant outside comments. Languages
        # with non-Ruby text override this to stay inside Ruby contexts.
        def rename_spans(analysis, name)
          analysis.lines.each_with_index.flat_map do |line_text, index|
            line_text.match?(/\A\s*#/) ? [] : Imports.constant_spans(line_text, index, name)
          end
        end

        def rename_target(analysis, position)
          target = target_at(analysis, position)
          target if target && %i[binding component].include?(target.kind)
        end

        # Every import literal that resolves to a file becomes a link.
        def document_links(analysis, workspace)
          links = []

          analysis.lines.each_with_index do |line_text, index|
            Imports.each_target(line_text, index) do |target|
              module_id = Imports.resolve(target, analysis, workspace)
              uri = module_id && workspace.uri_for_module_id(module_id)
              links << Imports::Interface::DocumentLink.new(range: target.span.to_range, target: uri) if uri
            end
          end

          links
        end

        # Every place the graph knows imports the target: import literals in
        # its dependents and, in Haml importers, the `%Component` tags bound to
        # it. `include_declaration` adds the target file itself.
        def reference_locations(target_module_id, index, workspace, include_declaration: false)
          locations = []

          index.dependents(target_module_id).each do |importer_id|
            record = index.record(importer_id)
            uri = record && workspace.uri_for_module_id(importer_id)
            next unless uri

            lines = record.source.lines(chomp: true)
            specifiers = record.resolved_dependencies.select { |resolved| resolved.module_id == target_module_id }.map { |resolved| resolved.dependency.specifier.to_s }.uniq
            specifiers.each do |specifier|
              span = Diagnostics.literal_span(specifier, lines)
              locations << Imports::Interface::Location.new(uri: uri, range: span.to_range) if span
            end
            usage_spans(importer_id, lines, specifiers).each do |span|
              locations << Imports::Interface::Location.new(uri: uri, range: span.to_range)
            end
          end

          if include_declaration && (uri = workspace.uri_for_module_id(target_module_id))
            locations << Imports::Interface::Location.new(uri: uri, range: Text.zero_range)
          end

          locations.uniq { |location| [location.uri, location.range.start.line, location.range.start.character] }
            .sort_by { |location| [location.uri, location.range.start.line, location.range.start.character] }
        end

        # `%Name` tags in a Haml importer whose binding refers to the target.
        def usage_spans(importer_id, lines, specifiers)
          return [] unless importer_id.extname == ".haml"

          names = Imports.bindings(lines).select { |_name, specifier| specifiers.include?(specifier) }.keys
          return [] if names.empty?

          spans = []
          lines.each_with_index do |line_text, index|
            Text.each_match(line_text, index, Languages::Haml::COMPONENT_TAG, group: :name) do |match, span|
              spans << span if names.include?(match[:name].split("::").first)
            end
          end
          spans
        end

        # Quick fixes replacing an unresolved import literal with each of the
        # build's own suggestions, for literals inside the requested lines.
        def code_actions(analysis, lines, workspace)
          uri = workspace.uri_for_module_id(analysis.module_id)
          return [] unless uri

          analysis.resolve_errors.flat_map do |error|
            specifier = error.requested_specifier
            span = specifier && Diagnostics.literal_span(specifier, analysis.lines)
            next [] unless span && lines.cover?(span.line)

            diagnostic = Diagnostics.diagnostic(span, error.message)
            error.suggestions.each_with_index.map do |suggestion, index|
              Imports::Interface::CodeAction.new(
                title: "Replace with #{suggestion.inspect}",
                kind: Imports::Constant::CodeActionKind::QUICK_FIX,
                diagnostics: [diagnostic],
                is_preferred: index.zero?,
                edit: Imports::Interface::WorkspaceEdit.new(
                  changes: {uri => [Imports::Interface::TextEdit.new(range: span.to_range, new_text: suggestion)]}
                )
              )
            end
          end
        end
      end
    end
  end
end
