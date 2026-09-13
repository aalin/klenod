# frozen_string_literal: true

require "language_server-protocol"

require_relative "../../text"

module Klenod
  module LSP
    module Languages
      class Haml
        # CSS class names in a Haml component: the `.name` shorthand on tags
        # and `ClassNames[:name]` lookups, checked against the class map of
        # the companion stylesheet and any inline `:css` filters. The map
        # comes from the graph's records, collected on demand.
        module Classes
          Interface = LanguageServer::Protocol::Interface
          Constant = LanguageServer::Protocol::Constant

          TAG_HEAD = /\A\s*(?:%[A-Za-z][\w:-]*)?(?<shorthand>(?:[.#][\w-]+)+)/
          SHORTHAND_CLASS = /\.(?<name>[\w-]+)/
          LOOKUP = /ClassNames\[:(?<name>[\w-]+)\]/
          SHORTHAND_PREFIX = /\A\s*(?:%[A-Za-z][\w:-]*)?(?:[.#][\w-]+)*\.(?<partial>[\w-]*)\z/
          LOOKUP_PREFIX = /ClassNames\[:(?<partial>[\w-]*)\z/
          STYLE_KINDS = %i[companion_style inline_style].freeze

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

          def occurrences(lines)
            lines.each_with_index.flat_map do |line_text, index|
              found = []
              if (head = TAG_HEAD.match(line_text))
                offset = head.begin(:shorthand)
                Text.each_match(head[:shorthand], index, SHORTHAND_CLASS, group: :name) do |match, span|
                  found << Occurrence.new(match[:name], span.with(start_character: span.start_character + offset, end_character: span.end_character + offset))
                end
              end
              Text.each_match(line_text, index, LOOKUP, group: :name) { |match, span| found << Occurrence.new(match[:name], span) }
              found
            end
          end

          def occurrence_at(lines, position)
            line_text = lines[position.line]
            return nil unless line_text

            occurrences([line_text]).map { |occurrence| occurrence.with(span: occurrence.span.with(line: position.line)) }
              .find { |occurrence| occurrence.span.include?(position) }
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
                message: "Unknown CSS class #{occurrence.name.inspect}: not defined in #{style_names(map, analysis).join(" or ")}"
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
            match = SHORTHAND_PREFIX.match(prefix) || LOOKUP_PREFIX.match(prefix)
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
