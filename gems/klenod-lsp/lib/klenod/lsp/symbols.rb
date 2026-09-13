# frozen_string_literal: true

require "language_server-protocol"

require "klenod/build/plugins/haml_plugin"

require_relative "languages/imports"
require_relative "text"

module Klenod
  module LSP
    # Outlines for documents and name search across the indexed graph.
    module Symbols
      Interface = LanguageServer::Protocol::Interface
      Constant = LanguageServer::Protocol::Constant

      COMPONENT_TAG = /%(?<name>[A-Z][A-Za-z0-9_:]*)/
      ELEMENT_TAG = /%(?<name>[a-z][A-Za-z0-9_-]*)/
      METHOD = /\A\s*def\s+(?<name>(?:self\.)?[A-Za-z_][A-Za-z0-9_]*[?!=]?)/
      WORKSPACE_LIMIT = 200

      module_function

      # The outline of a Haml component: constants and methods from the
      # leading `:ruby` filter, then the tag tree. Script lines such as
      # `- if` are transparent, so their children appear at the same level.
      def haml_document_symbols(source)
        lines = source.lines(chomp: true)
        root = Klenod::Build::Plugins::HamlPlugin.parse_haml(source)
        symbols_for_nodes(root.children, lines)
      rescue Klenod::Build::Error
        []
      end

      # Constants bound to imports, for Ruby modules.
      def binding_symbols(source)
        lines = source.lines(chomp: true)
        symbols = []
        lines.each_with_index do |line_text, index|
          Text.each_match(line_text, index, Languages::Imports::BINDING, group: :name) do |match, span|
            symbols << symbol(match[:name], Constant::SymbolKind::CONSTANT, Text.line_span(lines, index), span, detail: match[:specifier])
          end
        end
        symbols
      end

      # Modules under the source directory whose name or path matches the
      # query, as SymbolInformation so every client can show them.
      def workspace_symbols(query, index, workspace)
        needle = query.to_s.downcase
        matches = []

        index.records.each_key do |module_id|
          next unless module_id.scheme == :app && GraphIndex::ROOT_EXTENSIONS.include?(module_id.extname)

          relative = module_id.relative_path
          stylesheet = module_id.extname == ".css"
          name = stylesheet ? File.basename(relative) : File.basename(relative, module_id.extname)
          next unless needle.empty? || fuzzy_match?(name.downcase, needle) || relative.downcase.include?(needle)

          uri = workspace.uri_for_module_id(module_id)
          next unless uri

          matches << Interface::SymbolInformation.new(
            name: name,
            kind: symbol_kind(module_id),
            location: Interface::Location.new(uri: uri, range: Text.zero_range),
            container_name: File.dirname(relative)
          )
        end

        matches.sort_by { |symbol| [symbol.name.downcase, symbol.container_name] }.first(WORKSPACE_LIMIT)
      end

      def symbol_kind(module_id)
        case module_id.extname
        when ".haml" then Constant::SymbolKind::CLASS
        when ".css" then Constant::SymbolKind::FILE
        else Constant::SymbolKind::MODULE
        end
      end

      def symbols_for_nodes(nodes, lines)
        nodes.flat_map do |node|
          case node.type
          when :tag
            [tag_symbol(node, lines)]
          when :filter
            (node.value[:name] == "ruby") ? ruby_filter_symbols(node, lines) : []
          when :script, :silent_script
            symbols_for_nodes(node.children, lines)
          else
            []
          end
        end
      end

      def tag_symbol(node, lines)
        name = node.value.fetch(:name)
        line_index = node.line - 1
        component = name.match?(/\A[A-Z]/)
        span = tag_span(lines[line_index].to_s, line_index, component ? COMPONENT_TAG : ELEMENT_TAG, name)

        symbol(
          "%#{name}",
          component ? Constant::SymbolKind::CLASS : Constant::SymbolKind::FIELD,
          Text::Span.new(line_index, 0, 0).with(line: line_index),
          span,
          range_end: last_line(node),
          children: symbols_for_nodes(node.children, lines),
          lines: lines
        )
      end

      def ruby_filter_symbols(node, lines)
        symbols = []
        node.value.fetch(:text).to_s.each_line.with_index(node.line) do |text, line_index|
          if (match = Languages::Imports::BINDING.match(text))
            Text.each_match(lines[line_index].to_s, line_index, Languages::Imports::BINDING, group: :name) do |_match, span|
              symbols << symbol(match[:name], Constant::SymbolKind::CONSTANT, Text.line_span(lines, line_index), span, detail: match[:specifier])
            end
          elsif (match = METHOD.match(text))
            Text.each_match(lines[line_index].to_s, line_index, METHOD, group: :name) do |_match, span|
              symbols << symbol(match[:name], Constant::SymbolKind::METHOD, Text.line_span(lines, line_index), span)
            end
          end
        end
        symbols
      end

      def tag_span(line_text, line_index, pattern, name)
        Text.each_match(line_text, line_index, pattern, group: :name) do |match, span|
          return span if match[:name] == name
        end

        Text.line_span([line_text], 0).with(line: line_index)
      end

      def last_line(node)
        [node.line, *node.children.map { |child| last_line(child) }].max
      end

      def symbol(name, kind, full_span, selection_span, detail: nil, range_end: nil, children: nil, lines: nil)
        range =
          if range_end
            end_index = range_end - 1
            Interface::Range.new(
              start: Interface::Position.new(line: full_span.line, character: 0),
              end: Interface::Position.new(line: end_index, character: lines[end_index].to_s.length)
            )
          else
            full_span.to_range
          end

        Interface::DocumentSymbol.new(
          name: name,
          detail: detail,
          kind: kind,
          range: range,
          selection_range: selection_span.to_range,
          children: (children.nil? || children.empty?) ? nil : children
        )
      end

      def fuzzy_match?(name, needle)
        position = 0
        needle.each_char do |char|
          position = name.index(char, position)
          return false unless position

          position += 1
        end
        true
      end
    end
  end
end
