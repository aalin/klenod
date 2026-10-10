# frozen_string_literal: true

require "language_server-protocol"
require "prism"

require_relative "../../text"
require_relative "ruby_regions"

module Klenod
  module LSP
    module Languages
      class Haml
        # CSS class names in a Haml component: the `.name` shorthand on tags,
        # symbols in a tag's `class:` attribute, and `ClassNames[:name]`
        # lookups, checked against the class map of the companion stylesheet
        # and any inline `:css` filters. The map comes from the graph's
        # records, collected on demand.
        module Classes
          Interface = LanguageServer::Protocol::Interface
          Constant = LanguageServer::Protocol::Constant

          TAG_HEAD = /\A\s*(?:%[A-Za-z][\w:-]*)?(?<shorthand>(?:[.#][\w-]+)+)/
          SHORTHAND_CLASS = /\.(?<name>[\w-]+)/
          LOOKUP = /ClassNames\[:(?<name>[\w-]+)\]/
          SHORTHAND_PREFIX = /\A\s*(?:%[A-Za-z][\w:-]*)?(?:[.#][\w-]+)*\.(?<partial>[\w-]*)\z/
          LOOKUP_PREFIX = /ClassNames\[:(?<partial>[\w-]*)\z/
          CLASS_KEY_PREFIX = /(?:(?<![\w:])class:|:class\s*=>|["']class["']\s*(?::|=>))/
          SYMBOL_PREFIX = /(?:\A|[\s\[,]):(?<partial>[\w-]*)\z/
          OPENERS = "[{("
          CLOSERS = "]})"
          STYLE_KINDS = %i[companion_style inline_style].freeze
          FILTER_HEAD = /\A\s*:(?<name>\w+)/

          Occurrence = Data.define(:name, :span)
          Definition = Data.define(:module_id, :generated)

          module_function

          # Class name => Definition, or nil when the component has no styles
          # at all, in which case class names are plain HTML classes. While
          # the text does not transform, as with a half-typed attribute hash,
          # the module's last collected record supplies the stylesheets.
          def map(analysis, workspace, index)
            style_ids = style_module_ids(analysis, index)
            return nil if style_ids.empty?

            style_ids.each_with_object({}) do |module_id, map|
              record = style_record(module_id, workspace, index)
              next unless record

              record.metadata.fetch(:css_classes, {}).each do |key, generated|
                name = key.to_s
                next if name.start_with?("__")

                map[name] ||= Definition.new(module_id, generated)
              end
            end
          end

          def style_module_ids(analysis, index)
            if (transform = analysis.transform)
              transform.dependencies.filter_map do |dependency|
                next unless STYLE_KINDS.include?(dependency.kind)

                dependency.metadata[:virtual_module_id] || analysis.resolved_module_id_for(dependency.specifier.to_s)
              end
            else
              record = index.record(analysis.module_id)
              return [] unless record

              record.resolved_dependencies.filter_map { |resolved| resolved.module_id if STYLE_KINDS.include?(resolved.dependency.kind) }
            end
          end

          # Shorthand and `class:` attribute classes are only read outside
          # filters, so a `:ruby` method chain such as `.freeze` is not a
          # class. `ClassNames[:name]` lookups count everywhere.
          def occurrences(lines)
            filter_body = filter_body_lines(lines)
            lines.each_with_index.flat_map do |line_text, index|
              found = []
              unless filter_body.include?(index)
                if (head = TAG_HEAD.match(line_text))
                  offset = head.begin(:shorthand)
                  Text.each_match(head[:shorthand], index, SHORTHAND_CLASS, group: :name) do |match, span|
                    found << Occurrence.new(match[:name], span.with(start_character: span.start_character + offset, end_character: span.end_character + offset))
                  end
                end
                found.concat(attribute_occurrences(line_text, index))
              end
              Text.each_match(line_text, index, LOOKUP, group: :name) { |match, span| found << Occurrence.new(match[:name], span) }
              found
            end
          end

          # Symbols in the `class:` value of an attribute hash closed on the
          # tag line: `class: :name`, `:class => :name`, symbols in an array,
          # and symbol keys of a conditional hash such as `{ active: open? }`.
          # Computed values are left alone, and strings are unscoped classes.
          def attribute_occurrences(line_text, line_index)
            head = RubyRegions::TAG_HEAD.match(line_text)
            return [] unless head

            RubyRegions.attribute_regions(line_text[head.end(0)..].to_s).flat_map do |region_offset, region|
              next [] unless region.start_with?("{")

              result = Prism.parse(region)
              hash = result.value.statements.body.first
              next [] unless result.success? && hash.is_a?(Prism::HashNode)

              offset = head.end(0) + region_offset
              hash.elements.flat_map do |element|
                next [] unless element.is_a?(Prism::AssocNode) && class_key?(element.key)

                class_symbols(element.value).map do |symbol|
                  location = symbol.value_loc
                  Occurrence.new(
                    symbol.unescaped,
                    Text::Span.new(line_index, offset + location.start_character_offset, offset + location.end_character_offset)
                  )
                end
              end
            end
          end

          def class_key?(node)
            (node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)) && node.unescaped == "class"
          end

          def class_symbols(node)
            case node
            when Prism::SymbolNode
              node.value_loc ? [node] : []
            when Prism::ArrayNode
              node.elements.flat_map { class_symbols(it) }
            when Prism::HashNode, Prism::KeywordHashNode
              node.elements.flat_map do |element|
                (element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)) ? class_symbols(element.key) : []
              end
            else
              []
            end
          end

          def occurrence_at(lines, position)
            return nil unless lines[position.line]

            occurrences(lines).find { |occurrence| occurrence.span.include?(position) }
          end

          # Indexes of the lines inside filters: every line after a `:name`
          # line that is blank or indented deeper than it, as Haml reads them.
          # Indentation alone also works while the document does not parse.
          # Filters named in `except` are left out.
          def filter_body_lines(lines, except: [])
            filter_indent = nil
            lines.each_with_index.with_object(Set.new) do |(line_text, index), body|
              indent = line_text[/\A\s*/].length
              if filter_indent && (line_text.strip.empty? || indent > filter_indent)
                body << index
              else
                head = FILTER_HEAD.match(line_text)
                filter_indent = (head && !except.include?(head[:name])) ? indent : nil
              end
            end
          end

          # Warnings for classes the stylesheets do not define. Components
          # without styles are left alone.
          def diagnostics(analysis, workspace, index)
            map = map(analysis, workspace, index)
            return [] unless map

            occurrences(analysis.lines).filter_map do |occurrence|
              next if map.key?(occurrence.name)

              Interface::Diagnostic.new(
                range: occurrence.span.to_range,
                severity: Constant::DiagnosticSeverity::WARNING,
                source: "klenod",
                message: "Unknown CSS class `#{occurrence.name}`: not defined in #{style_names(map, analysis).map { |name| "`#{name}`" }.join(" or ")}"
              )
            end
          end

          # The selector in the stylesheet, or the `:css` filter line for an
          # inline stylesheet.
          def definition(occurrence, analysis, workspace, index)
            map = map(analysis, workspace, index)
            definition = map && map[occurrence.name]
            return nil unless definition

            selector_location(definition.module_id, occurrence.name, analysis, workspace, index)
          end

          def hover(occurrence, analysis, workspace, index)
            map = map(analysis, workspace, index)
            definition = map && map[occurrence.name]
            return nil unless definition

            value = "**.#{occurrence.name}** · `#{style_name(definition.module_id, analysis)}`\n\nRendered as `#{definition.generated}`"
            Interface::Hover.new(
              contents: Interface::MarkupContent.new(kind: Constant::MarkupKind::MARKDOWN, value: value),
              range: occurrence.span.to_range
            )
          end

          def completion_items(prefix, position, analysis, workspace, index)
            in_filter = filter_body_lines(analysis.lines).include?(position.line)
            match = (!in_filter && (SHORTHAND_PREFIX.match(prefix) || class_symbol_prefix(prefix))) || LOOKUP_PREFIX.match(prefix)
            return nil unless match

            map = map(analysis, workspace, index)
            return [] unless map

            partial = match[:partial]
            range = Text::Span.new(position.line, position.character - partial.length, position.character).to_range
            map.filter_map do |name, definition|
              next unless name.start_with?(partial)

              Interface::CompletionItem.new(
                label: name,
                kind: Constant::CompletionItemKind::PROPERTY,
                detail: style_name(definition.module_id, analysis),
                text_edit: Interface::TextEdit.new(range: range, new_text: name)
              )
            end
          end

          # A symbol being typed in a tag's `class:` value, such as
          # `%p{ class: [:lead, :k`. A comma outside brackets ends the value,
          # so the next attribute's symbols are not completed as classes.
          def class_symbol_prefix(prefix)
            return nil unless RubyRegions::TAG_HEAD.match?(prefix)

            key = prefix.to_enum(:scan, CLASS_KEY_PREFIX).map { Regexp.last_match }.last
            return nil unless key

            value = prefix[key.end(0)..]
            depth = 0
            value.each_char do |char|
              depth += 1 if OPENERS.include?(char)
              depth -= 1 if CLOSERS.include?(char)
              return nil if depth.negative? || (depth.zero? && char == ",")
            end

            SYMBOL_PREFIX.match(value)
          end

          def style_record(module_id, workspace, index)
            index.record(module_id) || workspace.context.graph.collect_module(module_id)
          rescue StandardError, ScriptError
            nil
          end

          def style_names(map, analysis)
            map.values.map(&:module_id).uniq.map { |module_id| style_name(module_id, analysis) }
          end

          def style_name(module_id, analysis)
            inline_origin(module_id, analysis) ? "inline :css" : module_id.path
          end

          def inline_origin(module_id, analysis)
            return nil unless module_id.scheme == :app && module_id.path.start_with?("#{analysis.module_id.path}.inline.")

            module_id
          end

          def selector_location(module_id, name, analysis, workspace, index)
            record = style_record(module_id, workspace, index)
            return nil unless record

            selector = /\.#{Regexp.escape(name)}(?![\w-])/
            css_lines = record.source.lines(chomp: true)
            line_index = css_lines.index { |line_text| line_text.match?(selector) }

            if inline_origin(module_id, analysis)
              origin = workspace.context.graph.virtual_module_metadata(module_id)[:inline_css_origin]
              uri = workspace.uri_for_module_id(analysis.module_id)
              return nil unless origin && uri && line_index

              haml_line = origin.fetch(:line_offset) + line_index
              column = css_lines[line_index].index(selector) + (line_index.zero? ? origin.fetch(:column_offset) : 0)
              Interface::Location.new(uri: uri, range: Text::Span.new(haml_line, column, column + name.length + 1).to_range)
            else
              uri = workspace.uri_for_module_id(module_id)
              return nil unless uri

              span = Text::Span.new(0, 0, 0)
              if line_index
                column = css_lines[line_index].index(selector)
                span = Text::Span.new(line_index, column, column + name.length + 1)
              end
              Interface::Location.new(uri: uri, range: span.to_range)
            end
          end
        end
      end
    end
  end
end
