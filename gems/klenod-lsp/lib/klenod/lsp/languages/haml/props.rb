# frozen_string_literal: true

require "did_you_mean"
require "language_server-protocol"

require_relative "../../text"
require_relative "../imports"
require_relative "rename"

module Klenod
  module LSP
    module Languages
      class Haml
        # The props a `%Component` tag passes, checked against the props the
        # component reads. Only keys written out on the tag line count:
        # `%Foo(bar="1"){ baz: 2 }`. A splat makes the tag unverifiable, and
        # a component that reads no `$props`, or reads them all with `$*`,
        # is left alone.
        module Props
          Interface = LanguageServer::Protocol::Interface
          Constant = LanguageServer::Protocol::Constant

          TAG_LINE = /\A\s*%(?<name>[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)(?:[.#][\w-]+)*/
          # `key="value"`, `key=value`, or a bare boolean `key`; a consumed
          # value cannot be mistaken for the next key.
          HTML_KEY = /(?<![\w-])(?<key>[A-Za-z_][\w-]*)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s()]+))?/
          HASH_KEYS = [
            /(?<=[{,]|\A)\s*(?<key>[A-Za-z_]\w*):(?!:)/,
            /(?<=[{,]|\A)\s*"(?<key>[^"]+)":/,
            /(?<=[{,]|\A)\s*:(?<key>\w+)\s*=>/,
            /(?<=[{,]|\A)\s*"(?<key>[^"]+)"\s*=>/
          ].freeze
          SPLAT = /\*\*/
          IMPLICIT = %w[children].freeze

          Key = Data.define(:name, :span)

          module_function

          def diagnostics(analysis, workspace, index)
            lines = analysis.lines
            bindings = Imports.bindings(lines)
            props_cache = {}

            lines.each_with_index.flat_map do |line_text, line_index|
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
              keys.reject { |key| allowed.include?(key.name) }.map { |key| diagnostic(key, tag[:name], allowed) }
            end
          end

          # Keys from the tag's attribute regions, or nil when a splat makes
          # them unknowable.
          def explicit_keys(rest, line_index, offset)
            keys = []
            Rename.attribute_regions(rest).each do |region_offset, region|
              return nil if region.start_with?("{") && region.match?(SPLAT)

              patterns = region.start_with?("(") ? [HTML_KEY] : HASH_KEYS
              inner = region[1...-1]
              patterns.each do |pattern|
                Text.each_match(inner, line_index, pattern, group: :key) do |match, span|
                  start = offset + region_offset + 1 + span.start_character
                  keys << Key.new(match[:key], Text::Span.new(line_index, start, start + match[:key].length))
                end
              end
            end
            keys.uniq { |key| key.span.start_character }
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
            suggestion = DidYouMean::SpellChecker.new(dictionary: allowed).correct(key.name).first
            message = "Unknown prop #{key.name.inspect} for #{tag_name}"
            message += "; did you mean #{suggestion.inspect}?" if suggestion

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
