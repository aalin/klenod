# frozen_string_literal: true

require "did_you_mean"
require "language_server-protocol"
require "prism"

require_relative "../../text"
require_relative "../imports"
require_relative "classes"
require_relative "ruby_regions"

module Klenod
  module LSP
    module Languages
      class Haml
        # The props a `%Component` tag passes, checked against the props the
        # component reads. Only keys written out on the tag line count:
        # `%Foo(bar="1"){ baz: 2 }`. A splat or attributes spanning several
        # lines make the tag unverifiable, and a component that reads no
        # `$props`, or reads them all with `$*`, is left alone.
        module Props
          Interface = LanguageServer::Protocol::Interface
          Constant = LanguageServer::Protocol::Constant

          TAG_LINE = /\A\s*%(?<name>[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)(?:[.#][\w-]+)*/
          # `key="value"`, `key=value`, or a bare boolean `key`; a consumed
          # value cannot be mistaken for the next key.
          HTML_KEY = /(?<![\w-])(?<key>[A-Za-z_][\w-]*)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s()]+))?/
          CLOSERS = {"{" => "}", "(" => ")", "[" => "]"}.freeze
          # Props every component accepts: Haml passes `children`, `%Foo[item]`
          # passes `key`, and `slot` places the component in its parent's slot.
          IMPLICIT = %w[children key slot].freeze

          Key = Data.define(:name, :span)

          module_function

          def diagnostics(analysis, workspace, index)
            lines = analysis.lines
            bindings = Haml.bindings(lines)
            props_cache = {}
            filter_body = Classes.filter_body_lines(lines)

            lines.each_with_index.flat_map do |line_text, line_index|
              next [] if filter_body.include?(line_index)

              tag = TAG_LINE.match(line_text)
              next [] unless tag

              constant = tag[:name].split("::").first
              specifier = bindings[constant]
              next [] unless specifier

              keys = explicit_keys(line_text[tag.end(0)..].to_s, line_index, tag.end(0))
              next [] if keys.nil? || keys.empty?

              props = props_cache[specifier] ||= component_props(specifier, analysis, workspace, index)
              next [] unless props && !props.splat && !props.names.empty?

              allowed = props.names + IMPLICIT
              keys.reject { |key| allowed.include?(prop_name(key.name)) }.map { |key| diagnostic(key, tag[:name], allowed) }
            end
          end

          # Components receive `video-id` as `$video_id`, like `merge_props`
          # in the Haml plugin's helper source.
          def prop_name(key)
            key.tr("-", "_")
          end

          # Keys from the tag's attribute regions, or nil when a splat or an
          # attribute list continuing on the next lines makes them unknowable.
          def explicit_keys(rest, line_index, offset)
            keys = []
            RubyRegions.attribute_regions(rest).each do |region_offset, region|
              return nil unless region.end_with?(CLOSERS.fetch(region[0]))

              if region.start_with?("{")
                hash_keys = explicit_hash_keys(region, line_index, offset + region_offset)
                return nil unless hash_keys

                keys.concat(hash_keys)
              elsif region.start_with?("(")
                Text.each_match(region[1...-1], line_index, HTML_KEY, group: :key) do |match, span|
                  start = offset + region_offset + 1 + span.start_character
                  keys << Key.new(match[:key], Text::Span.new(line_index, start, start + match[:key].length))
                end
              end
            end
            keys.uniq { |key| key.span.start_character }
          end

          # Only the outer hash supplies props. Keys in nested hashes, blocks,
          # and strings belong to values, and only an outer splat prevents us
          # from knowing which props the component receives.
          def explicit_hash_keys(source, line_index, offset)
            result = Prism.parse(source, partial_script: true)
            hash = result.value.statements.body.first
            return nil unless result.success? && hash.is_a?(Prism::HashNode)
            return nil if hash.elements.any? { |element| element.is_a?(Prism::AssocSplatNode) }

            hash.elements.filter_map do |element|
              name, location =
                case (key = element.key)
                when Prism::SymbolNode then [key.value, key.value_loc]
                when Prism::StringNode then [key.unescaped, key.content_loc]
                else next
                end
              start = offset + source.byteslice(0, location.start_offset).length
              Key.new(name, Text::Span.new(line_index, start, start + location.slice.length))
            end
          end

          def component_props(specifier, analysis, workspace, index)
            module_id = analysis.resolved_module_id_for(specifier) || workspace.resolve(specifier, importer_id: analysis.module_id)
            return nil unless module_id

            source = index.record(module_id)&.source
            path = workspace.path_for_module_id(module_id)
            source ||= File.read(path) if path && File.file?(path)
            return nil unless source && module_id.extname == ".haml"

            Imports.component_props(source, workspace)
          end

          def diagnostic(key, tag_name, allowed)
            suggestion = DidYouMean::SpellChecker.new(dictionary: allowed).correct(prop_name(key.name)).first
            message = "Unknown prop `#{key.name}` for `#{tag_name}`"
            message += "; did you mean `#{suggestion}`?" if suggestion

            Interface::Diagnostic.new(
              range: key.span.to_range,
              severity: Constant::DiagnosticSeverity::WARNING,
              source: "klenod",
              message: message
            )
          end
        end
      end
    end
  end
end
