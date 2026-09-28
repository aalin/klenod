# frozen_string_literal: true

require "prism"
require "ripper"

require_relative "dependency"
require_relative "errors"
require_relative "watched_pattern"

module Klenod
  module Build
    class RubyImportRewriter
      ImportCall =
        Data.define(:specifier, :location, :dynamic, :method_name, :eager_override, :import_name) do
          def eager
            eager_override.nil? ? RubyImportRewriter::IMPORT_METHODS.fetch(method_name).fetch(:eager) : eager_override
          end

          def replacement
            RubyImportRewriter::IMPORT_METHODS.fetch(method_name).fetch(:replacement)
          end
        end
      Result = Data.define(:code, :dependencies, :watched_patterns)
      # Character-based, so it indexes the source String directly.
      CallLocation = Data.define(:start_line, :start_column, :start_char, :end_char)

      IMPORT_METHODS = {
        "import" => {
          replacement: "__klenod_import__",
          eager: true
        },
        "lazy_import" => {
          replacement: "__klenod_lazy_import__",
          eager: false
        },
        "import_glob" => {
          replacement: nil,
          eager: true
        }
      }.freeze
      IMPORT_SOURCE_PATTERN = /(?<![A-Za-z0-9_])(?:import|lazy_import|import_glob)\s*(?:\(|["'])/
      FAST_LITERAL_IMPORT_PATTERN = /(?<![A-Za-z0-9_])(import|lazy_import)\s*\(\s*("(?:\\.|[^"\\#])*")\s*\)/

      # Ruby that does not parse, reported at its line in the enclosing
      # source. Haml wraps it into its own parse error with a source excerpt.
      class ParseError < Klenod::Build::Error
        attr_reader :line, :column

        def initialize(message, line:, column:)
          @line = line
          @column = column
          super(message)
        end
      end

      def initialize(module_id:, kind:, source_dir: nil, profiler: nil, dependency_id_offset: 0, source_line_offset: 0, source_column_offset: 0)
        @module_id = module_id
        @kind = kind
        @source_dir = source_dir && Pathname.new(source_dir).expand_path
        @profiler = profiler
        @dependency_id_offset = dependency_id_offset
        @source_line_offset = source_line_offset
        @source_column_offset = source_column_offset
      end

      def rewrite(code)
        return Result.new(code, [], []) unless import_source?(code)
        fast_result = rewrite_literal_import_calls(code)
        return fast_result if fast_result

        # Haml `:ruby` filters are fragments, so accept top-level `yield`,
        # `next`, and `break` like the rest of the Haml transform.
        result = measure(:ruby_import_parse) { Prism.parse(code, partial_script: true) }
        unless result.success?
          # Prism first reports an unclosed `{` or `(` at the line that opens
          # it. The unexpected token that broke it is the line to show.
          error = result.errors.reject { it.type.end_with?("_term") }.min_by { it.location.start_offset } || result.errors.first
          raise ParseError.new(
            error.message,
            line: error.location.start_line + @source_line_offset,
            column: error.location.start_character_column + 1 + @source_column_offset
          )
        end
        calls = measure(:ruby_import_scan) { import_calls(result.value) }
        expanded = expand_import_calls(calls)

        rewritten = measure(:ruby_import_rewrite_source) { rewrite_import_calls(code, expanded) }
        Result.new(
          rewritten,
          expanded.flat_map(&:dependencies),
          expanded.flat_map(&:watched_patterns)
        )
      end

      private

      ExpandedImport = Data.define(:call, :dependencies, :replacement_source, :watched_patterns)

      def import_source?(code)
        code.match?(IMPORT_SOURCE_PATTERN)
      end

      def rewrite_literal_import_calls(code)
        matches = []
        code.to_enum(:scan, IMPORT_SOURCE_PATTERN).each do
          start = Regexp.last_match.begin(0)
          match = FAST_LITERAL_IMPORT_PATTERN.match(code, start)
          return nil unless match && match.begin(0) == start

          matches << match
        end
        return nil if matches.empty?
        return nil unless bare_import_tokens?(code, matches)

        dependencies =
          matches.each_with_index.map do |match, index|
            specifier =
              begin
                match[2].undump
              rescue RuntimeError
                return nil
              end

            Dependency
              .create(
                specifier: specifier,
                importer_id: @module_id,
                kind: @kind,
                loc: source_location_for_offset(code, match.begin(0))
              )
              .with(eager: IMPORT_METHODS.fetch(match[1]).fetch(:eager))
              .with(id: "#{@module_id}:dependency:#{@dependency_id_offset + index}")
          end

        rewritten =
          matches
            .zip(dependencies)
            .reverse_each
            .each_with_object(code.dup) do |(match, dependency), source|
              replacement = IMPORT_METHODS.fetch(match[1]).fetch(:replacement)
              source[match.begin(0)...match.end(0)] = "#{replacement}(#{dependency.id.inspect})"
            end

        Result.new(rewritten, dependencies, [])
      end

      def bare_import_tokens?(code, matches)
        match_starts = matches.to_h { |match| [match.begin(1), match[1]] }
        return true if match_starts.empty?

        line_offsets = line_offsets_for(code)
        previous_significant_token = nil
        matched = {}

        Ripper.lex(code).each do |(line, column), type, token, _state|
          offset = line_offsets.fetch(line - 1) + column
          expected = match_starts[offset]
          if expected
            return false unless type == :on_ident && token == expected
            return false if receiver_token?(previous_significant_token)

            matched[offset] = true
          end

          previous_significant_token = [type, token] unless insignificant_token?(type)
        end

        matched.length == match_starts.length
      end

      def receiver_token?(token)
        token == [:on_period, "."] || token == [:on_op, "::"] || token == [:on_op, "&."]
      end

      def line_offsets_for(code)
        offsets = [0]
        code.each_line(chomp: false) { |line| offsets << offsets.last + line.length }
        offsets
      end

      def insignificant_token?(type)
        type == :on_sp || type == :on_ignored_nl || type == :on_nl || type == :on_comment
      end

      def measure(name, &block)
        return yield unless @profiler

        @profiler.measure(name, module_id: @module_id.to_s, kind: @kind, &block)
      end

      def import_calls(node)
        visitor = ImportCallVisitor.new
        node.accept(visitor)
        visitor.calls.map { |call| build_import_call(call) }
      end

      class ImportCallVisitor < Prism::Visitor
        attr_reader :calls

        def initialize
          @calls = []
          super
        end

        def visit_call_node(node)
          @calls << node if import_call?(node)
          super
        end

        private

        # A bare `import` without arguments or parentheses is an ordinary
        # method call or local variable, not an import.
        def import_call?(node)
          node.receiver.nil? &&
            IMPORT_METHODS.key?(node.name.to_s) &&
            !(node.arguments.nil? && node.opening_loc.nil?)
        end
      end
      private_constant :ImportCallVisitor

      def build_import_call(node)
        arguments = node.arguments&.arguments || []
        return build_import_glob(node, arguments) if node.name == :import_glob

        specifier = string_literal_value(arguments.first)
        import_name = (arguments.length == 2) ? constant_symbol_value(arguments.fetch(1)) : nil
        literal = !specifier.nil? && (arguments.length == 1 || !import_name.nil?)

        ImportCall.new(
          literal ? specifier : nil,
          call_location(node),
          !literal,
          node.name.to_s,
          nil,
          literal ? import_name : nil
        )
      end

      # A Prism call's location includes an attached block, so the rewritten
      # range ends at the closing parenthesis or the last argument.
      def call_location(node)
        last = node.closing_loc || node.arguments&.location || node.message_loc

        CallLocation.new(
          node.location.start_line,
          node.location.start_character_column,
          node.location.start_character_offset,
          last.end_character_offset
        )
      end

      # A plain string literal without interpolation, such as `"./Card.haml"`.
      def string_literal_value(node)
        node = unwrap_parentheses(node)
        return unless node.is_a?(Prism::StringNode) && !node.heredoc? && !node.unescaped.empty?

        node.unescaped
      end

      # The optional second argument of `import`: a symbol literal spelled like
      # a constant, such as `:Bar`. Anything else (`:bar`, `:"Bar"`, a string,
      # a variable) is reported as a dynamic import.
      def constant_symbol_value(node)
        return unless node.is_a?(Prism::SymbolNode) && node.opening_loc&.slice == ":"

        value = node.unescaped
        value.match?(/\A[A-Z]\w*\z/) ? value.to_sym : nil
      end

      def build_import_glob(node, arguments)
        specifier = string_literal_value(arguments.first)
        literal = !specifier.nil?

        eager = true
        valid_options = true
        if arguments.length == 2
          eager = eager_option_value(arguments.fetch(1))
          valid_options = !eager.nil?
        elsif arguments.length != 1
          valid_options = false
        end

        ImportCall.new(
          (literal && valid_options) ? specifier : nil,
          call_location(node),
          !literal || !valid_options,
          node.name.to_s,
          eager,
          nil
        )
      end

      def eager_option_value(node)
        return unless node.is_a?(Prism::KeywordHashNode) && node.elements.length == 1

        assoc = node.elements.fetch(0)
        return unless assoc.is_a?(Prism::AssocNode)

        key = assoc.key
        return unless key.is_a?(Prism::SymbolNode) && key.opening_loc.nil? && key.unescaped == "eager"

        case assoc.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        end
      end

      def unwrap_parentheses(node)
        return node unless node.is_a?(Prism::ParenthesesNode)

        body = node.body.is_a?(Prism::StatementsNode) ? node.body.body : []
        (body.length == 1) ? body.first : node
      end

      def expand_import_calls(calls)
        dependency_index = @dependency_id_offset

        calls.map do |call|
          raise_dynamic_import!(call) if call.dynamic

          if call.method_name == "import_glob"
            dependencies, watched_patterns = expand_glob_import(call, dependency_index)
            dependency_index += dependencies.length
            ExpandedImport.new(call, dependencies, glob_replacement_source(dependencies, eager: call.eager), watched_patterns)
          else
            dependency = build_dependency(call, dependency_index)
            dependency_index += 1
            ExpandedImport.new(call, [dependency], "#{call.replacement}(#{dependency.id.inspect})", [])
          end
        end
      end

      def raise_dynamic_import!(call)
        expected =
          if call.method_name == "import_glob"
            "import_glob(\"...\")"
          else
            "#{call.method_name}(\"...\") or #{call.method_name}(\"...\", :Constant)"
          end
        raise DynamicImportError, "Only literal #{expected} calls are supported in #{@module_id}"
      end

      def build_dependency(call, dependency_index)
        dependency =
          Dependency
            .create(
              specifier: call.specifier,
              importer_id: @module_id,
              kind: @kind,
              loc: source_location(call.location)
            )
            .with(eager: call.eager)
            .with(id: "#{@module_id}:dependency:#{dependency_index}")
        return dependency unless call.import_name

        dependency.with(metadata: {import_name: call.import_name}.freeze)
      end

      def expand_glob_import(call, dependency_index)
        source_dir = @source_dir || raise(DynamicImportError, "Cannot expand import_glob in #{@module_id} without a source directory")
        path_pattern, query = call.specifier.split("?", 2)
        absolute_pattern = absolute_pattern_for(path_pattern)
        assert_pattern_inside_source_dir!(absolute_pattern)

        matches =
          Dir
            .glob(absolute_pattern.to_s)
            .select { |path| File.file?(path) }
            .sort

        dependencies =
          matches.each_with_index.map do |absolute_path, index|
            specifier = specifier_for_glob_match(path_pattern, absolute_path)
            specifier = "#{specifier}?#{query}" if query

            Dependency
              .create(
                specifier: specifier,
                importer_id: @module_id,
                kind: @kind,
                loc: source_location(call.location)
              )
              .with(eager: call.eager)
              .with(metadata: {glob_key: specifier.split("?", 2).first})
              .with(id: "#{@module_id}:dependency:#{dependency_index + index}")
          end

        watched_patterns = [
          WatchedPattern.new(
            @module_id,
            absolute_pattern.relative_path_from(source_dir).to_s,
            :import_glob,
            {specifier: call.specifier}
          )
        ]

        [dependencies, watched_patterns]
      end

      def source_location(location)
        SourceLocation.new(
          @module_id.to_s,
          location.start_line + @source_line_offset,
          location.start_column + 1 + @source_column_offset
        )
      end

      def source_location_for_offset(source, offset)
        prefix = source[0...offset]
        line = prefix.count("\n") + 1
        column = prefix.length - (prefix.rindex("\n") || -1)
        SourceLocation.new(@module_id.to_s, line + @source_line_offset, column + @source_column_offset)
      end

      def absolute_pattern_for(path_pattern)
        source_dir = @source_dir

        if path_pattern.start_with?("/")
          source_dir.join(path_pattern.delete_prefix("/"))
        elsif path_pattern.start_with?(".")
          source_dir.join(@module_id.dirname, path_pattern)
        else
          source_dir.join(path_pattern)
        end.expand_path
      end

      def assert_pattern_inside_source_dir!(absolute_pattern)
        pattern = absolute_pattern.to_s
        source = @source_dir.to_s
        return if pattern == source || pattern.start_with?("#{source}/")

        raise DynamicImportError, "Glob import escapes source_dir: #{pattern}"
      end

      def specifier_for_glob_match(path_pattern, absolute_path)
        relative_source_path = Pathname.new(absolute_path).relative_path_from(@source_dir).to_s
        return "/#{relative_source_path}" if path_pattern.start_with?("/")
        return relative_source_path unless path_pattern.start_with?(".")

        importer_dir = @source_dir.join(@module_id.dirname)
        relative = Pathname.new(absolute_path).relative_path_from(importer_dir).to_s
        relative.start_with?(".") ? relative : "./#{relative}"
      end

      def glob_replacement_source(dependencies, eager:)
        import_method = eager ? "__klenod_import__" : "__klenod_lazy_import__"
        entries =
          dependencies.map do |dependency|
            key = dependency.metadata.fetch(:glob_key)
            "#{key.inspect} => #{import_method}(#{dependency.id.inspect})"
          end

        "{#{entries.join(", ")}}"
      end

      def rewrite_import_calls(code, expanded)
        expanded
          .reverse_each
          .each_with_object(code.dup) do |import, rewritten|
            call = import.call
            next rewritten if call.dynamic

            location = call.location
            original = code[location.start_char...location.end_char]
            unless original.match?(/\A#{Regexp.escape(call.method_name)}\s*\(/)
              raise DynamicImportError, "Could not safely rewrite import at #{location.start_line}:#{location.start_column}"
            end

            rewritten[location.start_char...location.end_char] = import.replacement_source
          end
      end
    end
  end
end
