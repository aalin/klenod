# frozen_string_literal: true

require "syntax_tree"
require "syntax_tree/dsl"
require "syntax_tree/haml"

require_relative "../../source_map"
require_relative "../plugin"
require_relative "../dependency"
require_relative "../module_id"
require_relative "../ruby_import_rewriter"
require_relative "../transform_result"
require_relative "../watched_pattern"
require_relative "intl_plugin"

module Klenod
  module Build
    module Plugins
      class HamlPlugin < Plugin
        HamlTransformResult = Data.define(:code, :source_map, :metadata)

        DEFAULT_COMPONENT_BASE_CLASS = "Object"
        DEFAULT_FACTORY = "Object"

        class DefaultTransformer
          VALID_CONST_PATH = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

          ConstPath = Data.define(:value) do
            def self.parse(value, name:)
              path = value.to_s
              raise ArgumentError, "#{name} must be a Ruby constant path" unless path.match?(VALID_CONST_PATH)

              new(path)
            end

            def to_s
              value
            end
          end

          class RubyBuilder
            include SyntaxTree::DSL

            Fragment = Data.define(:source, :node) do
              def marked?
                source.include?(SourceMap::MARK_PREFIX)
              end

              def to_s
                source
              end
            end

            def component_source(
              component_class_name:,
              component_base_class:,
              translations_source:,
              ruby_source:,
              render_source:,
              styles_source:
            )
              source =
                <<~RUBY
                  # frozen_string_literal: true

                  KlenodImport = method(:__klenod_import__)

                  class #{component_class_name} < #{component_base_class}
                    def self.module_path
                      __FILE__
                    end

                    Self = self
                    Translations = #{translations_source}

                    def self.__klenod_import__(dependency_id)
                      KlenodImport.call(dependency_id)
                    end

                    def __klenod_import__(dependency_id)
                      self.class.__klenod_import__(dependency_id)
                    end

                  #{indent(ruby_source, 2)}

                    public def render
                  #{indent(to_source(render_source), 4)}
                    end
                  end

                  Default = #{component_class_name}
                  Styles = #{styles_source}
                  Default.const_set(:Styles, Styles)
                  Translations = Default::Translations
                RUBY

              program(source).source
            end

            def expressions(expressions)
              return ast_expressions(expressions) unless marked?(expressions)

              sources = expressions.map { |expression| to_source(expression) }
              source =
                case sources.length
                when 0 then "nil"
                when 1 then sources.fetch(0)
                else "[\n#{indent(sources.join(",\n"), 2)}\n]"
                end

              expression(source)
            end

            def expression(source)
              node = parse_expression(source)
              formatted_source =
                if node && !source.include?(SourceMap::MARK_PREFIX)
                  format_node(node)
                else
                  source
                end

              Fragment.new(formatted_source, node)
            end

            def statements(source)
              node = parse_statements(source)

              Fragment.new(node ? format(source) : source, node)
            end

            def program(source)
              node = parse_program(source)

              Fragment.new(node ? format_node(node) : source, node)
            end

            def fragment(node)
              Fragment.new(format_node(node), node)
            end

            def to_source(value)
              value.is_a?(Fragment) ? value.source : value.to_s
            end

            def literal(value)
              expression(value.inspect)
            end

            def frozen_literal(value)
              fragment(frozen_literal_node(value))
            end

            def symbol(value)
              expression(value.to_sym.inspect)
            end

            def parenthesized_expression(source)
              node = parse_expression(source)
              return expression("(#{source})") unless node

              fragment(Paren(LParen("("), Statements([node])))
            end

            def source_mark(line_no, source)
              "# #{SourceMap::Mark.new(line_no, source)}"
            end

            def marked_expression(mark, expression)
              source = to_source(expression)

              Fragment.new("#{mark}\n#{source}", expression.is_a?(Fragment) ? expression.node : parse_expression(source))
            end

            def factory_call(factory:, tag:, children:, props:, mark: nil)
              return ast_factory_call(factory: factory, tag: tag, children: children, props: props) unless marked?(children)

              arguments = [tag, *children.map { |child| to_source(child) }, keyword_props(props, mark: mark)].compact.join(",\n")

              expression("#{factory}[\n#{indent(arguments, 2)}\n]")
            end

            def script_block(source, body)
              ast_script_block(source, body) || expression("#{source}\n#{indent(to_source(body), 2)}\nend")
            end

            def silent_script(source)
              ast_silent_script(source) || expression("begin\n#{indent(source, 2)}\n  nil\nend")
            end

            def branches(branches)
              ast_branches(branches) || expression(branches.map { |source, body| "#{source}\n#{indent(to_source(body), 2)}" }.join("\n") + "\nend")
            end

            def ruby_filters(nodes)
              return "" if nodes.empty?

              ast_ruby_filters(nodes) || statements(nodes.map { |node| "begin\n#{indent(node, 2)}\nend" }.join("\n"))
            end

            def format(source)
              SyntaxTree.format(source)
            rescue SyntaxTree::Parser::ParseError
              source
            end

            def format_node(node)
              SyntaxTree::Formatter.format(+"", node, 0)
            end

            def indent(value, spaces)
              to_source(value).lines.map { |line| "#{" " * spaces}#{line}" }.join
            end

            private

            def ast_expressions(expressions)
              case expressions.length
              when 0
                node = VarRef(Kw("nil"))

                Fragment.new(format_node(node), node)
              when 1
                expression = expressions.fetch(0)

                expression.is_a?(Fragment) ? expression : self.expression(to_source(expression))
              else
                node = ArrayLiteral(LBracket("["), Args(expressions.map { |item| expression_node(to_source(item)) }))

                Fragment.new(format_node(node), node)
              end
            end

            def ast_factory_call(factory:, tag:, children:, props:)
              parts = [
                expression_node(factory),
                expression_node(tag),
                *children.map { |child| expression_node(to_source(child)) },
                ast_keyword_props(props)
              ].compact
              factory_node = parts.shift

              node = ARef(factory_node, Args(parts))

              Fragment.new(format_node(node), node)
            end

            def ast_silent_script(source)
              statements = parse_statements(source)
              return nil unless statements

              node = ast_begin([*statements.body, VarRef(Kw("nil"))])

              Fragment.new(format_node(node), node)
            end

            def ast_script_block(source, body)
              return nil if body.respond_to?(:marked?) && body.marked?

              skeleton = parse_expression("#{source}\n  nil\nend")
              return nil unless skeleton.is_a?(SyntaxTree::MethodAddBlock)

              body_node = expression_node(to_source(body))
              node =
                skeleton.copy(
                  block: skeleton.block.copy(
                    bodystmt: BodyStmt(
                      Statements([body_node]),
                      nil,
                      nil,
                      nil,
                      nil
                    )
                  )
                )

              Fragment.new(format_node(node), node)
            end

            def ast_branches(branches)
              return nil if branches.any? { |_source, body| body.respond_to?(:marked?) && body.marked? }

              skeleton_source, body_branches = branch_skeleton(branches)
              skeleton = parse_expression(skeleton_source)
              return nil unless skeleton.is_a?(SyntaxTree::IfNode) || skeleton.is_a?(SyntaxTree::Case)

              bodies = body_branches.map { |_source, body| expression_node(to_source(body)) }
              node = replace_branch_bodies(skeleton, bodies)
              return nil unless bodies.empty?

              Fragment.new(format_node(node), node)
            end

            def ast_ruby_filters(nodes)
              begins =
                nodes.map do |node|
                  statements = parse_statements(node)
                  return nil unless statements

                  ast_begin(statements.body)
                end

              statements(format_node(Statements(begins)))
            end

            def ast_begin(statement_nodes)
              Begin(
                BodyStmt(
                  Statements(statement_nodes),
                  nil,
                  nil,
                  nil,
                  nil
                )
              )
            end

            def replace_branch_bodies(node, bodies)
              case node
              when SyntaxTree::IfNode, SyntaxTree::Elsif, SyntaxTree::When
                node.copy(
                  statements: Statements([bodies.shift]),
                  consequent: node.consequent ? replace_branch_bodies(node.consequent, bodies) : nil
                )
              when SyntaxTree::Else
                node.copy(statements: Statements([bodies.shift]))
              when SyntaxTree::Case
                node.copy(consequent: replace_branch_bodies(node.consequent, bodies))
              end
            end

            def branch_skeleton(branches)
              first_source, first_body = branches.fetch(0)
              if first_source.match?(/\Acase\b/) && to_source(first_body) == "nil"
                [
                  "#{first_source}\n#{branches.drop(1).map { |source, _body| "#{source}\n  nil" }.join("\n")}\nend",
                  branches.drop(1)
                ]
              else
                [
                  "#{branches.map { |source, _body| "#{source}\n  nil" }.join("\n")}\nend",
                  branches
                ]
              end
            end

            def ast_keyword_props(props)
              return nil if props.empty?

              AssocSplat(
                HashLiteral(
                  LBrace("{"),
                  props.map { |name, value| Assoc(Label("#{name}:"), expression_node(value)) }
                )
              )
            end

            def frozen_literal_node(value)
              case value
              when Hash
                freeze_node(
                  HashLiteral(
                    LBrace("{"),
                    value.map { |key, child| Assoc(literal_node(key), frozen_literal_node(child)) }
                  )
                )
              when Array
                freeze_node(ArrayLiteral(LBracket("["), Args(value.map { |child| frozen_literal_node(child) })))
              else
                literal_node(value)
              end
            end

            def literal_node(value)
              expression_node(value.inspect)
            end

            def freeze_node(node)
              CallNode(node, Period("."), Ident("freeze"), nil)
            end

            def keyword_props(props, mark:)
              return nil if props.empty?

              "#{mark},\n**{#{props.map { |name, value| "#{name.inspect} => #{to_source(value)}" }.join(", ")}}"
            end

            def marked?(values)
              values.any? { |value| value.respond_to?(:marked?) && value.marked? }
            end

            def expression_node(source)
              source = source.to_s

              parse_expression(source) || raise(ArgumentError, "Could not parse Ruby expression: #{source.inspect}")
            end

            def parse_expression(source)
              SyntaxTree
                .parse(source)
                &.statements
                &.body
                &.find { |node| !node.instance_of?(SyntaxTree::Comment) }
            rescue SyntaxTree::Parser::ParseError
              nil
            end

            def parse_statements(source)
              SyntaxTree.parse(source)&.statements
            rescue SyntaxTree::Parser::ParseError
              nil
            end

            def parse_program(source)
              SyntaxTree.parse(source)
            rescue SyntaxTree::Parser::ParseError
              nil
            end
          end

          def call(
            source:,
            module_id:,
            component_class_name:,
            component_base_class:,
            factory:,
            styles_source:,
            translations_source:
          )
            component_base_class = ConstPath.parse(component_base_class, name: "component_base_class")
            factory = ConstPath.parse(factory, name: "factory")
            builder = RubyBuilder.new
            template = compile_template(source, factory: factory, builder: builder)
            code =
              builder.component_source(
                component_class_name: component_class_name,
                component_base_class: component_base_class,
                translations_source: translations_source,
                ruby_source: template.ruby_source,
                render_source: template.render_source,
                styles_source: styles_source
              )

            HamlTransformResult.new(
              code,
              SourceMap::SourceMap.parse(source, code),
              {source: source, module_id: module_id}
            )
          end

          private

          Template = Data.define(:ruby_source, :render_source)
          RubyLine = Data.define(:line_no, :source)

          def compile_template(source, factory:, builder:)
            parsed = SyntaxTree::Haml.parse(source)
            render_nodes = parsed.children.reject { |node| ruby_filter?(node) }
            ruby_nodes = parsed.children.select { |node| ruby_filter?(node) }
            ruby_source = compile_ruby_filters(ruby_nodes, builder: builder)
            render_source = compile_nodes(render_nodes, factory: factory, builder: builder)

            Template.new(ruby_source, render_source)
          end

          def compile_nodes(nodes, factory:, builder:)
            builder.expressions(compile_node_expressions(nodes, factory: factory, builder: builder))
          end

          def compile_node_expressions(nodes, factory:, builder:)
            expressions = []
            index = 0

            while index < nodes.length
              node = nodes.fetch(index)

              if script_node?(node) && !continuation?(node)
                group = [node]
                index += 1

                while index < nodes.length && continuation?(nodes.fetch(index))
                  group << nodes.fetch(index)
                  index += 1
                end

                expressions << compile_script_group(group, factory: factory, builder: builder)
              else
                expressions << compile_node(node, factory: factory, builder: builder)
                index += 1
              end
            end

            expressions
          end

          def compile_node(node, factory:, builder:)
            mark = source_mark(node, builder: builder)
            expression =
              case node.type
              when :tag
                compile_tag(node, factory: factory, builder: builder)
              when :plain
                builder.literal(node.value.fetch(:text))
              when :script
                compile_script(node, factory: factory, builder: builder)
              when :silent_script
                compile_silent_script(node, factory: factory, builder: builder)
              when :filter
                compile_filter_node(node, builder: builder)
              end

            builder.marked_expression(mark, expression)
          end

          def compile_script_group(nodes, factory:, builder:)
            return compile_node(nodes.fetch(0), factory: factory, builder: builder) if nodes.length == 1

            compile_branches(
              nodes.map { |node| [script_source(node), node.children] },
              factory: factory,
              builder: builder
            )
          end

          def compile_script(node, factory:, builder:)
            source = script_source(node)
            return builder.parenthesized_expression(source) if node.children.empty?

            builder.script_block(source, compile_nodes(node.children, factory: factory, builder: builder))
          end

          def compile_silent_script(node, factory:, builder:)
            source = script_source(node)
            return builder.silent_script(source) if node.children.empty?

            compile_branches(split_silent_script_branches(node), factory: factory, builder: builder)
          end

          def compile_branches(branches, factory:, builder:)
            builder.branches(
              branches.map do |source, children|
                [source, compile_nodes(children, factory: factory, builder: builder)]
              end
            )
          end

          def split_silent_script_branches(node)
            branches = []
            current_source = script_source(node)
            current_children = []

            node.children.each do |child|
              if continuation?(child)
                branches << [current_source, current_children]
                current_source = script_source(child)
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

          def script_source(node)
            node.value.fetch(:text).strip
          end

          def continuation?(node)
            script_node?(node) && %w[elsif else when in rescue ensure].include?(node.value.fetch(:keyword))
          end

          def compile_tag(node, factory:, builder:)
            children = []
            value = node.value.fetch(:value)
            if value && !value.empty?
              children << (node.value.fetch(:parse) ? builder.parenthesized_expression(value) : builder.literal(value))
            end
            children.concat(compile_node_expressions(node.children, factory: factory, builder: builder))

            compile_factory_call(node, children, factory: factory, builder: builder)
          end

          def compile_factory_call(node, children, factory:, builder:)
            builder.factory_call(
              factory: factory,
              tag: compile_tag_name(node, builder: builder),
              children: children,
              props: attributes(node, builder: builder),
              mark: source_mark(node, builder: builder)
            )
          end

          def compile_tag_name(node, builder:)
            tag_name = node.value.fetch(:name)
            tag_name.match?(/\A[A-Z]/) ? builder.expression(tag_name) : builder.symbol(tag_name)
          end

          def attributes(node, builder:)
            static_attributes(node, builder: builder).merge(dynamic_attributes(node, builder: builder))
          end

          def compile_ruby_filters(nodes, builder:)
            builder.ruby_filters(nodes.map { |node| compile_ruby_filter(node, builder: builder) })
          end

          def compile_ruby_filter(node, builder:)
            node.value.fetch(:text)
              .lines
              .map
              .with_index(node.line + 1) do |line, line_no|
                "#{source_mark(RubyLine.new(line_no, line.strip), builder: builder)}\n#{line.chomp}"
              end
              .join("\n")
          end

          def compile_filter_node(node, builder:)
            raise ArgumentError, "Only :ruby Haml filters are supported" unless ruby_filter?(node)

            builder.literal(node.value.fetch(:text))
          end

          def ruby_filter?(node)
            node.type == :filter && node.value.fetch(:name) == "ruby"
          end

          def static_attributes(node, builder:)
            node
              .value
              .fetch(:attributes)
              .to_h { |key, value| [key.to_sym, builder.literal(value)] }
          end

          def dynamic_attributes(node, builder:)
            source = node.value.fetch(:dynamic_attributes).old
            return {} unless source

            ast = SyntaxTree.parse(source)
            hash = ast&.statements&.body&.first
            return {} unless hash.is_a?(SyntaxTree::HashLiteral)

            hash.assocs.to_h do |assoc|
              [attribute_key(assoc.key, builder: builder), builder.fragment(assoc.value)]
            end
          end

          def attribute_key(node, builder:)
            case node
            when SyntaxTree::Label
              node.value.delete_suffix(":").to_sym
            else
              builder.format_node(node).to_sym
            end
          end

          def source_mark(node, builder:)
            line_no = node.is_a?(RubyLine) ? node.line_no : node.line

            builder.source_mark(line_no, source_for_mark(node))
          end

          def source_for_mark(node)
            case node
            when RubyLine
              node.source
            else
              case node.type
              when :tag
                node.value.fetch(:value) || node.value.fetch(:name)
              when :plain
                node.value.fetch(:text)
              when :script
                node.value.fetch(:text)
              when :silent_script
                node.value.fetch(:text)
              when :filter
                node.value.fetch(:name).to_s
              end
            end
          end
        end

        def initialize(
          component_base_class: DEFAULT_COMPONENT_BASE_CLASS,
          factory: DEFAULT_FACTORY,
          transformer: DefaultTransformer.new
        )
          @component_base_class = component_base_class
          @factory = factory
          @transformer = transformer
        end

        def transform(module_id, code, context)
          return super unless module_id.extname == ".haml"

          companion_css = companion_path(module_id, ".css")
          dependencies = []
          builder = DefaultTransformer::RubyBuilder.new
          styles_source = builder.frozen_literal({}).source

          if context.absolute_path(companion_css).file?
            dependency =
              Dependency
                .create(
                  specifier: "./#{File.basename(companion_css.path)}",
                  importer_id: module_id,
                  kind: :companion_style,
                  metadata: {optional: true}
                )
                .with(id: "#{module_id}:companion_style")
            dependencies << dependency
            styles_source = builder.expression("__klenod_import__(#{dependency.id.inspect})").source
          end
          translations_source = builder.frozen_literal(translations_for(context, module_id)).source
          component_class_name = component_class_name(module_id)
          haml_result =
            @transformer.call(
              source: code,
              module_id: module_id,
              component_class_name: component_class_name,
              component_base_class: @component_base_class,
              factory: @factory,
              styles_source: styles_source,
              translations_source: translations_source
            )
          import_rewrite = RubyImportRewriter.new(module_id: module_id, kind: :haml_import).rewrite(haml_result.code)

          TransformResult.new(
            import_rewrite.code,
            dependencies + import_rewrite.dependencies,
            haml_result.source_map,
            [],
            companion_patterns(module_id),
            haml_result.metadata
          )
        end

        def import_value(_resolved_dependency, record, context)
          return nil unless record.id.extname == ".haml"

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        private

        def translations_for(context, module_id)
          intl_plugin = context.plugins.find { |plugin| plugin.respond_to?(:translations_for) }
          intl_plugin ? intl_plugin.translations_for(context, module_id) : {}
        end

        def component_class_name(module_id)
          basename = File.basename(module_id.path, ".haml")
          classified =
            basename
              .split(/[^A-Za-z0-9]+/)
              .reject(&:empty?)
              .map { |part| part[0].upcase + part[1..] }
              .join

          classified.empty? ? "Component" : classified
        end

        def companion_patterns(module_id)
          base = module_id.path.delete_suffix(".haml")

          [
            WatchedPattern.new(module_id, "#{base}.css", :companion_style, {}),
            WatchedPattern.new(module_id, "#{base}.intl.*.toml", :companion_intl, {})
          ]
        end

        def companion_path(module_id, extname)
          ModuleId.new(module_id.path.delete_suffix(".haml") + extname, nil)
        end
      end
    end
  end
end
