# frozen_string_literal: true

require "syntax_tree"
require "ripper"

require "klenod/runtime/source_map"
require_relative "../markdown_compiler"
require_relative "parser"

module Klenod
  module Build
    module Plugins
      module HamlPlugin
        class Transformer
          VALID_CONST_PATH = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

          ConstPath = ::Data.define(:value) do
            def self.parse(value, name:)
              path = value.to_s
              raise ArgumentError, "#{name} must be a Ruby constant path" unless path.match?(VALID_CONST_PATH)

              new(path)
            end

            def to_s
              value
            end
          end

          require_relative "transformer/ruby_builder"
          def call(
            source:,
            module_id:,
            component_class_name:,
            component_base_class:,
            factory:,
            styles_source:,
            translations_source:,
            i18n_source: nil,
            styleable: false,
            profiler: nil,
            import_rewriter: nil,
            markdown_components_source: "{}",
            global_variables: nil,
            haml_helper_source: nil,
            cache_static_subtrees: false
          )
            component_base_class = ConstPath.parse(component_base_class, name: "component_base_class")
            factory = ConstPath.parse(factory, name: "factory")
            builder = RubyBuilder.new(profiler: profiler, global_variables: global_variables)
            haml_helper_source ||= builder.constant_assignment("HamlHelper", "Object") if styleable || cache_static_subtrees
            previous_profiler = @profiler
            previous_module_id = @module_id
            previous_static_constants = @static_constants
            previous_cache_static_subtrees = @cache_static_subtrees
            @profiler = profiler
            @module_id = module_id
            @static_constants = []
            @cache_static_subtrees = cache_static_subtrees
            template =
              if profiler
                profiler.measure(:haml_compile_template, module_id: module_id.to_s) do
                  compile_template(
                    source,
                    module_id: module_id,
                    factory: factory,
                    styleable: styleable,
                    builder: builder,
                    import_rewriter: import_rewriter,
                    markdown_components_source: markdown_components_source
                  )
                end
              else
                compile_template(
                  source,
                  module_id: module_id,
                  factory: factory,
                  styleable: styleable,
                  builder: builder,
                  import_rewriter: import_rewriter,
                  markdown_components_source: markdown_components_source
                )
              end
            ast =
              if profiler
                profiler.measure(:haml_component_program, module_id: module_id.to_s) do
                  builder.component_program(
                    component_class_name: component_class_name,
                    component_base_class: component_base_class,
                    translations_source: translations_source,
                    ruby_source: template.ruby,
                    render_source: template.render,
                    styles_source: styles_source,
                    haml_helper_source: haml_helper_source,
                    i18n_source: i18n_source,
                    static_constants: template.static_constants
                  )
                end
              else
                builder.component_program(
                  component_class_name: component_class_name,
                  component_base_class: component_base_class,
                  translations_source: translations_source,
                  ruby_source: template.ruby,
                  render_source: template.render,
                  styles_source: styles_source,
                  haml_helper_source: haml_helper_source,
                  i18n_source: i18n_source,
                  static_constants: template.static_constants
                )
              end
            if profiler
              code = profiler.measure(:haml_generate_code, module_id: module_id.to_s) { ast.source }
              source_map =
                profiler.measure(:haml_source_map_parse, module_id: module_id.to_s) do
                  Runtime::SourceMap::SourceMap.parse(source, code)
                end

              HamlTransformResult.new(code, source_map, {source: source, module_id: module_id}, ast)
            else
              HamlTransformResult.from_ast(
                ast,
                source: source,
                metadata: {source: source, module_id: module_id}
              )
            end
          rescue RubyParseError => error
            raise ParseError.new(error, source: source, module_id: module_id)
          ensure
            @profiler = previous_profiler
            @module_id = previous_module_id
            @static_constants = previous_static_constants
            @cache_static_subtrees = previous_cache_static_subtrees
          end

          private

          Template = ::Data.define(:ruby, :render, :static_constants)

          def measure_compile(name)
            return yield unless @profiler

            @profiler.measure(name, module_id: @module_id.to_s) { yield }
          end

          def measure_compile_detail(name)
            return yield unless @profiler&.category?(:haml_detail)

            @profiler.measure(name, module_id: @module_id.to_s) { yield }
          end

          def compile_template(source, factory:, builder:, module_id: nil, styleable: false, import_rewriter: nil, markdown_components_source: "{}")
            parsed = measure_compile(:haml_parse_haml) { HamlPlugin.parse_haml(source, module_id: module_id) }
            render_nodes, ruby_nodes =
              measure_compile(:haml_partition_top_level_nodes) do
                partition_top_level_nodes(parsed.children)
              end
            ruby =
              if ruby_nodes.empty?
                ""
              else
                measure_compile(:haml_compile_ruby_filters) { compile_ruby_filters(ruby_nodes, builder: builder, import_rewriter: import_rewriter) }
              end
            markdown_compiler = MarkdownCompiler.new(factory: factory, components_source: markdown_components_source)
            render =
              measure_compile(:haml_compile_render_nodes) do
                compile_nodes(render_nodes, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)
              end

            Template.new(ruby, render, @static_constants)
          end

          def partition_top_level_nodes(nodes)
            class_ruby_nodes = []
            render_nodes = []
            class_ruby_seen = false

            nodes.each do |node|
              if css_filter?(node)
                next
              elsif !class_ruby_seen && ruby_filter?(node)
                class_ruby_seen = true
                class_ruby_nodes << node
              else
                render_nodes << node
              end
            end

            [render_nodes, class_ruby_nodes]
          end

          def compile_nodes(nodes, factory:, builder:, markdown_compiler:, styleable: false)
            expressions =
              measure_compile(:haml_compile_node_expressions) do
                compile_node_expressions(nodes, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)
              end

            measure_compile(:haml_build_expression_list) { builder.expressions(expressions) }
          end

          def compile_node_expressions(nodes, factory:, builder:, markdown_compiler:, styleable: false)
            expressions = []
            previous_node = nil
            index = 0

            while index < nodes.length
              node = nodes[index]

              if script_node?(node) && !continuation?(node)
                group = [node]
                index += 1

                while index < nodes.length && continuation?(nodes[index])
                  group << nodes[index]
                  index += 1
                end

                expression = compile_script_group(group, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)
              else
                expression = compile_node(node, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)
                index += 1
              end

              expressions << builder.literal(" ") if previous_node && whitespace_boundary_node?(node) && whitespace_between?(previous_node, node)
              expressions << expression
              previous_node = node if whitespace_boundary_node?(node)
            end

            expressions
          end

          def whitespace_boundary_node?(node)
            !(node.type == :silent_script && node.children.empty?)
          end

          def whitespace_between?(left, right)
            (right.type == :tag && right.value.fetch(:nuke_inner_whitespace)) ||
              (left.type == :tag && left.value.fetch(:nuke_outer_whitespace))
          end

          def cache_static_subtree?(node, styleable:)
            @cache_static_subtrees && static_subtree?(node, styleable: styleable)
          end

          def register_static_subtree(builder, expression)
            name = "STATIC_SUBTREE_#{@static_constants.length}"
            @static_constants << builder.constant_assignment(name, builder.freeze_static(expression))
            builder.expression(name)
          end

          def static_subtree?(node, styleable:)
            return false unless node.type == :tag
            return false if styleable
            return false if slot_tag?(node)
            return false if constant_tag_name?(node.value.fetch(:name))
            return false unless static_tag_value?(node)
            return false unless static_tag_attributes?(node)

            node.children.all? { |child| static_child_node?(child, styleable: styleable) }
          end

          def static_child_node?(node, styleable:)
            case node.type
            when :plain
              true
            when :tag
              static_subtree?(node, styleable: styleable)
            else
              false
            end
          end

          def static_tag_value?(node)
            value = node.value.fetch(:value)
            !node.value.fetch(:parse) || value.nil? || value.empty?
          end

          def static_tag_attributes?(node)
            value = node.value
            dynamic = value.fetch(:dynamic_attributes)
            return false if dynamic.old || dynamic.new
            return false if value.fetch(:object_ref).is_a?(String)
            return false if value.fetch(:attributes).key?("class")

            true
          end

          def compile_node(node, factory:, builder:, markdown_compiler:, styleable: false)
            measure_compile_detail(:"haml_compile_node_#{node.type}") do
              mark = source_mark(node, builder: builder)
              expression =
                case node.type
                when :tag
                  if slot_tag?(node)
                    builder.marked_expression(mark, compile_slot(node, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler))
                  elsif cache_static_subtree?(node, styleable: styleable)
                    tag_expression = builder.marked_expression(mark, compile_tag(node, mark: mark, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler))
                    builder.marked_expression(mark, register_static_subtree(builder, tag_expression))
                  else
                    builder.marked_expression(mark, compile_tag(node, mark: mark, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler))
                  end
                when :plain
                  builder.literal(node.value.fetch(:text))
                when :script
                  compile_script(node, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)
                when :silent_script
                  compile_silent_script(node, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)
                when :filter
                  compile_filter_node(node, builder: builder, markdown_compiler: markdown_compiler)
                end

              (node.type == :tag) ? expression : builder.marked_expression(mark, expression)
            end
          end

          def compile_script_group(nodes, factory:, builder:, markdown_compiler:, styleable: false)
            return compile_script_branch(nodes[0], factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler) if nodes.length == 1 && branch_start?(nodes[0])
            return compile_node(nodes[0], factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler) if nodes.length == 1

            compile_branches(
              nodes.map { |node| [script_source(node, builder: builder), node.children] },
              factory: factory,
              styleable: styleable,
              builder: builder,
              markdown_compiler: markdown_compiler
            )
          end

          def compile_script(node, factory:, builder:, markdown_compiler:, styleable: false)
            source = script_source(node, builder: builder)
            return builder.parenthesized_expression(source) if node.children.empty?

            builder.script_block(
              source,
              compile_nodes(node.children, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler),
              line_no: node.line
            )
          end

          def compile_script_branch(node, factory:, builder:, markdown_compiler:, styleable: false)
            compile_branches(
              [[script_source(node, builder: builder), node.children]],
              factory: factory,
              styleable: styleable,
              builder: builder,
              markdown_compiler: markdown_compiler
            )
          end

          def compile_silent_script(node, factory:, builder:, markdown_compiler:, styleable: false)
            source = script_source(node, builder: builder)
            return builder.silent_script(source) if node.children.empty?
            if builder.block_script?(source)
              return builder.silent_script_block(
                source,
                compile_nodes(node.children, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler),
                line_no: node.line
              )
            end

            compile_silent_branches(
              split_silent_script_branches(node, builder: builder),
              factory: factory,
              styleable: styleable,
              builder: builder,
              markdown_compiler: markdown_compiler
            )
          end

          def compile_branches(branches, factory:, builder:, markdown_compiler:, styleable: false)
            builder.branches(
              branches.map do |source, children|
                [source, compile_nodes(children, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)]
              end
            )
          end

          def compile_silent_branches(branches, factory:, builder:, markdown_compiler:, styleable: false)
            builder.silent_branches(
              branches.map do |source, children|
                [source, compile_nodes(children, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)]
              end
            )
          end

          def split_silent_script_branches(node, builder:)
            branches = []
            current_source = script_source(node, builder: builder)
            current_children = []

            node.children.each do |child|
              if continuation?(child)
                branches << [current_source, current_children]
                current_source = script_source(child, builder: builder)
                current_children = child.children.dup
              else
                current_children << child
              end
            end

            branches << [current_source, current_children]
          end

          def script_node?(node)
            node.type == :script || node.type == :silent_script
          end

          def script_source(node, builder:)
            builder.line_rewritten_source(node.value.fetch(:text).strip, node.line)
          end

          def continuation?(node)
            script_node?(node) && %w[elsif else when in rescue ensure].include?(node.value.fetch(:keyword))
          end

          def branch_start?(node)
            node.type == :script && %w[if unless case begin].include?(node.value.fetch(:keyword))
          end

          def compile_tag(node, mark:, factory:, builder:, markdown_compiler:, styleable: false)
            children = []
            measure_compile_detail(:haml_compile_tag_value) do
              value = node.value.fetch(:value)
              if value && !value.empty?
                children << (node.value.fetch(:parse) ? builder.parenthesized_expression(value, line_no: node.line) : builder.literal(value))
              end
            end
            unless node.children.empty?
              children.concat(
                measure_compile_detail(:haml_compile_tag_children) do
                  compile_node_expressions(node.children, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)
                end
              )
            end

            measure_compile(:haml_compile_factory_call) { compile_factory_call(node, children, mark: mark, factory: factory, styleable: styleable, builder: builder) }
          end

          def slot_tag?(node)
            node.value.fetch(:name) == "slot"
          end

          def compile_slot(node, factory:, builder:, markdown_compiler:, styleable: false)
            props = attributes(node, styleable: false, builder: builder)
            name = props.delete(:name)
            fallback =
              if node.children.empty?
                nil
              else
                compile_nodes(node.children, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler)
              end
            builder.slot_call(name: name, fallback: fallback)
          end

          def compile_factory_call(node, children, mark:, factory:, builder:, styleable: false)
            tag = measure_compile_detail(:haml_compile_tag_name) { compile_tag_name(node, builder: builder) }
            props = measure_compile_detail(:haml_compile_tag_attributes) { attributes(node, styleable: styleable, builder: builder) }

            builder.factory_call(
              factory: factory,
              tag: tag,
              children: children,
              props: props,
              mark: mark
            )
          end

          def compile_tag_name(node, builder:)
            tag_name = node.value.fetch(:name)
            constant_tag_name?(tag_name) ? builder.expression(tag_name) : builder.symbol_fragment(tag_name)
          end

          def attributes(node, builder:, styleable: false)
            value = node.value
            static = value.fetch(:attributes)
            dynamic = value.fetch(:dynamic_attributes)
            object_ref = value.fetch(:object_ref)
            return {} if !styleable && static.empty? && !dynamic.old && !dynamic.new && !object_ref.is_a?(String)

            measure_compile(:haml_compile_attributes) do
              props = {}
              static_attributes(node, builder: builder, props: props)
              dynamic = dynamic_attributes(node, builder: builder, props: props)
              object_ref_attributes(node, builder: builder, props: props)
              class_attributes(node, dynamic_attributes: dynamic, builder: builder, props: props, styleable: styleable)
              props
            end
          end

          def compile_ruby_filters(nodes, builder:, import_rewriter: nil)
            builder.ruby_filters(nodes.map { |node| compile_ruby_filter(node, builder: builder, import_rewriter: import_rewriter) })
          end

          def compile_ruby_filter(node, builder:, import_rewriter: nil)
            text = node.value.fetch(:text)
            text = import_rewriter.call(text) if import_rewriter && text.include?("import")
            heredoc_body_lines = ruby_heredoc_body_lines(text)
            source = +""
            text.each_line.with_index(node.line + 1) do |line, line_no|
              source << "\n" unless source.empty?
              relative_line_no = line_no - node.line

              if heredoc_body_lines.key?(relative_line_no)
                source << line.chomp
              else
                source << builder.source_mark(line_no, nil)
                source << "\n"
                source << builder.line_rewritten_source(line.chomp, line_no).chomp
              end
            end

            builder.node_fragment(source, nil)
          end

          def ruby_heredoc_body_lines(source)
            starts = []
            lines = {}

            ::Ripper.lex(source).each do |(line_no, _column), token, _text, _state|
              case token
              when :on_heredoc_beg
                starts << line_no
              when :on_heredoc_end
                start_line = starts.shift
                next unless start_line

                ((start_line + 1)..line_no).each { |body_line| lines[body_line] = true }
              end
            end

            lines
          end

          def compile_filter_node(node, builder:, markdown_compiler:)
            return builder.render_ruby_filter(compile_ruby_filter(node, builder: builder)) if ruby_filter?(node)
            return builder.expression(markdown_compiler.compile(node.value.fetch(:text), interpolate: true)) if markdown_filter?(node)

            raise ArgumentError, "Only :ruby and :markdown Haml filters are supported"
          end

          def ruby_filter?(node)
            node.type == :filter && node.value.fetch(:name) == "ruby"
          end

          def markdown_filter?(node)
            node.type == :filter && node.value.fetch(:name) == "markdown"
          end

          def css_filter?(node)
            node.type == :filter && node.value.fetch(:name) == "css"
          end

          def static_attributes(node, builder:, props:)
            attributes = node.value.fetch(:attributes)
            return if attributes.empty? || (attributes.length == 1 && attributes.key?("class"))

            measure_compile(:haml_compile_static_attributes) do
              attributes.each do |key, value|
                next if key == "class"

                props[key.to_sym] = builder.literal(value)
              end
            end
          end

          def dynamic_attributes(node, builder:, props:)
            dynamic_attributes = node.value.fetch(:dynamic_attributes)
            source = dynamic_attributes.old || dynamic_attributes.new
            return {} unless source

            measure_compile(:haml_compile_dynamic_attributes) do
              source = builder.line_rewritten_source(source, node.line)
              simple = simple_dynamic_attributes(source, builder: builder)
              if simple
                simple.each { |key, value| props[key] = value }
                return simple
              end

              hash = builder.hash_expression(source, line_no: node.line)
              unless hash
                builder.ruby_parse_error(source, line_no: node.line, context: "Could not parse Haml dynamic attributes")
              end

              dynamic = {}
              hash.node.assocs.each do |assoc|
                key = attribute_key(assoc.key, builder: builder)
                value = attribute_value(assoc, source, builder: builder)
                dynamic[key] = value
                props[key] = value
              end
              dynamic
            end
          end

          def simple_dynamic_attributes(source, builder:)
            source = source.strip
            return nil unless source.start_with?("{") && source.end_with?("}")

            pairs = split_simple_attribute_pairs(source[1...-1].strip)
            return nil unless pairs

            pairs.to_h do |pair|
              match = pair.match(/\A([a-zA-Z_]\w*):\s*(.+)\z/m)
              return nil unless match

              value = match[2].strip
              return nil if value.empty?

              fragment = builder.expression(value)
              return nil unless fragment.node

              [match[1].to_sym, fragment]
            end
          end

          def split_simple_attribute_pairs(source)
            return [] if source.empty?

            pairs = []
            start = 0
            quote = nil
            escaped = false

            source.each_byte.with_index do |byte, index|
              if quote
                if escaped
                  escaped = false
                elsif byte == 92 # \
                  escaped = true
                elsif byte == quote
                  quote = nil
                end
                next
              end

              case byte
              when 34, 39 # " '
                quote = byte
              when 40, 41, 91, 93, 123, 125 # ( ) [ ] { }
                return nil
              when 44 # ,
                pairs << source[start...index].strip
                start = index + 1
              end
            end

            return nil if quote

            pairs << source[start..].strip
            pairs
          end

          def class_attributes(node, dynamic_attributes:, builder:, props:, styleable: false)
            attributes = node.value.fetch(:attributes)
            static_class_source = attributes.fetch("class", "")
            dynamic_class = dynamic_attributes[:class]
            return unless styleable || !static_class_source.empty? || dynamic_class

            measure_compile(:haml_compile_class_attributes) do
              class_metadata = node.value.fetch(:klenod_class_metadata, {})
              literal_static_classes = class_metadata.fetch(:literal, [])
              scoped_static_classes = class_metadata.fetch(:shorthand, static_class_source.split)
              class_values = [
                tag_class_symbol(node, builder: builder),
                *scoped_static_classes.map { |class_name| builder.symbol(class_name) },
                *literal_static_classes.map { |class_name| builder.literal(class_name) },
                dynamic_class
              ].compact
              unless class_values.any?
                props[:class] = dynamic_class if dynamic_class
                return
              end

              props[:class] = builder.scoped_class_name(class_values)
            end
          end

          def tag_class_symbol(node, builder:)
            tag_name = node.value.fetch(:name)
            return nil if constant_tag_name?(tag_name)

            builder.symbol("__#{tag_name}")
          end

          def constant_tag_name?(tag_name)
            first = tag_name.getbyte(0)
            first && first >= 65 && first <= 90
          end

          def object_ref_attributes(node, builder:, props:)
            source = node.value.fetch(:object_ref)
            return unless source.is_a?(String)

            measure_compile(:haml_compile_object_ref_attributes) do
              expression = builder.expression(source, line_no: node.line)
              key =
                if expression.node.is_a?(SyntaxTree::ArrayLiteral) && expression.node.contents&.parts&.length == 1
                  builder.fragment(expression.node.contents.parts.fetch(0))
                else
                  expression
                end

              props[:key] = key
            end
          end

          def node_source(source, node)
            location = node.location
            return source unless location

            source[location.start_char...location.end_char]
          end

          def attribute_value(assoc, source, builder:)
            value = assoc.value
            return builder.node_fragment(node_source(source, value), value) if value

            key = omitted_attribute_value_name(assoc.key)
            return builder.expression(key) if key

            builder.ruby_parse_error(source, line_no: assoc.key.location&.start_line, context: "Could not parse Haml dynamic attributes")
          end

          def omitted_attribute_value_name(node)
            case node
            when SyntaxTree::Label
              name = node.value.delete_suffix(":")
              name if name.match?(/\A[a-zA-Z_]\w*\z/)
            end
          end

          def attribute_key(node, builder:)
            case node
            when SyntaxTree::Label
              node.value.delete_suffix(":").to_sym
            when SyntaxTree::DynaSymbol
              static_dyna_symbol_value(node)&.to_sym || builder.fragment(node).source.to_sym
            when SyntaxTree::StringLiteral
              node.parts.map(&:value).join.to_sym
            else
              builder.fragment(node).source.to_sym
            end
          end

          def static_dyna_symbol_value(node)
            values =
              node.parts.map do |part|
                return nil unless part.is_a?(SyntaxTree::TStringContent)

                part.value
              end

            values.join
          end

          def source_mark(node, builder:)
            builder.source_mark(node.line, nil)
          end
        end
      end
    end
  end
end
