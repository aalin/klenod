# frozen_string_literal: true

require_relative "../diagnostics"
require_relative "../text"

module Klenod
  module LSP
    module Languages
      # Diagnostics and navigation for Haml component modules.
      #
      # The Haml parser reports lines only, so everything here recovers
      # columns by scanning the original line text.
      class Haml
        Interface = LanguageServer::Protocol::Interface

        IMPORT_CALL = /\b(?<call>(?:lazy_)?import(?:_glob)?)\(\s*(?<quote>["'])(?<specifier>[^"']*)\k<quote>/
        COMPONENT_TAG = /%(?<name>[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)/

        def diagnostics(analysis)
          Diagnostics.for_analysis(analysis)
        end

        def definition(analysis, position, workspace)
          lines = analysis.lines
          line_text = lines[position.line]
          return nil unless line_text

          specifier = import_specifier_at(line_text, position) || component_specifier_at(line_text, position, lines)
          return nil unless specifier

          module_id = analysis.resolved_module_id_for(specifier) || workspace.resolve(specifier, importer_id: analysis.module_id)
          return nil unless module_id

          uri = workspace.uri_for_module_id(module_id)
          return nil unless uri

          Interface::Location.new(uri: uri, range: Text.zero_range)
        end

        private

        def import_specifier_at(line_text, position)
          Text.each_match(line_text, position.line, IMPORT_CALL, group: :specifier) do |match, span|
            next if match[:call] == "import_glob"

            return match[:specifier] if span.include?(position)
          end

          nil
        end

        # `%Details` compiles to the constant `Details`, bound by an import in
        # the leading `:ruby` filter such as `Details = import("components/Details")`.
        def component_specifier_at(line_text, position, lines)
          Text.each_match(line_text, position.line, COMPONENT_TAG, group: :name) do |match, span|
            next unless span.include?(position)

            return binding_specifier(match[:name].split("::").first, lines)
          end

          nil
        end

        def binding_specifier(constant_name, lines)
          binding = /\A\s*#{Regexp.escape(constant_name)}\s*=\s*(?:lazy_)?import\(\s*(?<quote>["'])(?<specifier>[^"']*)\k<quote>/

          lines.each do |line_text|
            match = binding.match(line_text)
            return match[:specifier] if match
          end

          nil
        end
      end
    end
  end
end
