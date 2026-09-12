# frozen_string_literal: true

require_relative "../diagnostics"
require_relative "../text"
require_relative "haml/completion"
require_relative "haml/hover"

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
        BINDING = /\A\s*(?<name>[A-Z][A-Za-z0-9_]*)\s*=\s*(?:lazy_)?import\(\s*(?<quote>["'])(?<specifier>[^"']*)\k<quote>/

        # Something under the cursor that names another module: an import
        # literal or a `%Component` tag bound by an import.
        Target = Data.define(:kind, :name, :specifier, :span)

        def diagnostics(analysis)
          Diagnostics.for_analysis(analysis)
        end

        def definition(analysis, position, workspace)
          target = target_at(analysis, position)
          return nil unless target

          module_id = resolve_target(target, analysis, workspace)
          uri = module_id && workspace.uri_for_module_id(module_id)
          return nil unless uri

          Interface::Location.new(uri: uri, range: Text.zero_range)
        end

        def hover(analysis, position, workspace)
          target = target_at(analysis, position)
          return nil unless target

          module_id = resolve_target(target, analysis, workspace)
          return nil unless module_id

          Hover.call(target, module_id, workspace)
        end

        def completion(analysis, position, workspace)
          Completion.call(analysis, position, workspace)
        end

        def target_at(analysis, position)
          line_text = analysis.lines[position.line]
          return nil unless line_text

          import_target_at(line_text, position) || component_target_at(line_text, position, analysis.lines)
        end

        def resolve_target(target, analysis, workspace)
          analysis.resolved_module_id_for(target.specifier) || workspace.resolve(target.specifier, importer_id: analysis.module_id)
        end

        # `%Details` compiles to the constant `Details`, bound by an import in
        # the leading `:ruby` filter such as `Details = import("/components/Details")`.
        def self.bindings(lines)
          lines.each_with_object({}) do |line_text, bindings|
            match = BINDING.match(line_text)
            bindings[match[:name]] ||= match[:specifier] if match
          end
        end

        private

        def import_target_at(line_text, position)
          Text.each_match(line_text, position.line, IMPORT_CALL, group: :specifier) do |match, span|
            next if match[:call] == "import_glob"

            return Target.new(:import, match[:specifier], match[:specifier], span) if span.include?(position)
          end

          nil
        end

        def component_target_at(line_text, position, lines)
          Text.each_match(line_text, position.line, COMPONENT_TAG, group: :name) do |match, span|
            next unless span.include?(position)

            constant_name = match[:name].split("::").first
            specifier = self.class.bindings(lines)[constant_name]
            return specifier && Target.new(:component, match[:name], specifier, span)
          end

          nil
        end
      end
    end
  end
end
