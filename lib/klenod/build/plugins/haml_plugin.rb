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
        HamlTransformResult = Data.define(:code, :source_map, :metadata, :ast) do
          def self.from_ast(ast, source:, metadata:)
            new(
              ast.source,
              SourceMap::SourceMap.parse(source, ast.source),
              metadata,
              ast
            )
          end
        end

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
              def node?
                !node.nil?
              end

              def statement_body
                node.is_a?(SyntaxTree::Statements) ? node.body : [node].compact
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
              component_program(
                component_class_name: component_class_name,
                component_base_class: component_base_class,
                translations_source: translations_source,
                ruby_source: ruby_source,
                render_source: render_source,
                styles_source: styles_source
              ).source
            end

            def component_program(
              component_class_name:,
              component_base_class:,
              translations_source:,
              ruby_source:,
              render_source:,
              styles_source:
            )
              component_class_name = expression_fragment(component_class_name)
              component_base_class = expression_fragment(component_base_class)
              translations_source = expression_fragment(translations_source)
              ruby_source = statements_fragment(ruby_source)
              render_source = expression_fragment(render_source)
              styles_source = expression_fragment(styles_source)

              header = [
                fragment(comment_node("# frozen_string_literal: true")),
                constant_assignment(
                  "KlenodImport",
                  call(receiver: nil, name: "method", arguments: [symbol("__klenod_import__")])
                )
              ]
              component_class =
                component_class_fragment(
                  component_class_name: component_class_name,
                  component_base_class: component_base_class,
                  translations_source: translations_source,
                  ruby_source: ruby_source,
                  render_source: render_source
                )
              footer = [
                constant_assignment("Default", component_class_name),
                constant_assignment("Styles", styles_source),
                call(receiver: "Default", name: "const_set", arguments: [symbol("Styles"), "Styles"]),
                constant_assignment("Translations", "Default::Translations")
              ]

              program_from_fragments(header, component_class, footer)
            end

            def component_class_fragment(
              component_class_name:,
              component_base_class:,
              translations_source:,
              ruby_source:,
              render_source:
            )
              skeleton = class_skeleton_fragment(component_class_name, component_base_class)
              body =
                [
                  method_definition("module_path", target: "self", body: file_expression),
                  constant_assignment("Self", "self"),
                  constant_assignment("Translations", translations_source),
                  method_definition(
                    "__klenod_import__",
                    target: "self",
                    parameters: ["dependency_id"],
                    body: call(receiver: "KlenodImport", name: "call", arguments: ["dependency_id"])
                  ),
                  method_definition(
                    "__klenod_import__",
                    parameters: ["dependency_id"],
                    body: call(receiver: "self.class", name: "__klenod_import__", arguments: ["dependency_id"])
                  ),
                  ruby_source,
                  public_method_definition("render", body: render_source)
                ].flat_map { |fragment| statement_body_for(fragment) }

              fragment(
                skeleton.node.copy(
                  bodystmt: BodyStmt(
                    Statements(body),
                    nil,
                    nil,
                    nil,
                    nil
                  )
                )
              )
            end

            def expressions(expressions)
              ast_expressions(expressions)
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

              Fragment.new(node ? format_node(node) : source, node)
            end

            def program(source)
              node = parse_program(source)

              Fragment.new(node ? format_node(node) : source, node)
            end

            def program_from_fragments(*fragments)
              body = fragments.flatten.flat_map { |fragment| statement_body_for(fragment) }

              fragment(Program(Statements(body)))
            end

            def fragment(node)
              Fragment.new(format_node(node), node)
            end

            def expression_fragment(value)
              value.is_a?(Fragment) ? value : expression(value.to_s)
            end

            def statements_fragment(value)
              value.is_a?(Fragment) ? value : statements(value.to_s)
            end

            def to_source(value)
              value.is_a?(Fragment) ? value.source : value.to_s
            end

            def literal(value)
              fragment(literal_node(value))
            end

            def frozen_literal(value)
              fragment(frozen_literal_node(value))
            end

            def import_call(dependency_id)
              fragment(
                CallNode(
                  nil,
                  nil,
                  Ident("__klenod_import__"),
                  ArgParen(Args([literal_node(dependency_id)]))
                )
              )
            end

            def constant_assignment(name, value)
              fragment(Assign(VarField(Const(name.to_s)), node_for(expression_fragment(value))))
            end

            def call(receiver:, name:, arguments:)
              receiver_node = receiver.nil? ? nil : node_for(expression_fragment(receiver))

              fragment(
                CallNode(
                  receiver_node,
                  receiver_node ? Period(".") : nil,
                  Ident(name.to_s),
                  ArgParen(Args(arguments.map { |argument| node_for(expression_fragment(argument)) }))
                )
              )
            end

            def method_definition(name, body:, target: nil, parameters: [])
              fragment(
                DefNode(
                  target && node_for(expression_fragment(target)),
                  target ? Period(".") : nil,
                  Ident(name.to_s),
                  Params(parameters.map { |parameter| Ident(parameter.to_s) }, [], nil, [], [], nil, nil),
                  body_statement(body)
                )
              )
            end

            def public_method_definition(name, body:, parameters: [])
              fragment(
                Command(
                  Ident("public"),
                  Args([method_definition(name, parameters: parameters, body: body).node]),
                  nil
                )
              )
            end

            def nil_expression
              fragment(nil_node)
            end

            def file_expression
              fragment(VarRef(Kw("__FILE__")))
            end

            def symbol(value)
              fragment(symbol_node(value.to_s))
            end

            def parenthesized_expression(source)
              node = parse_expression(source)
              return expression("(#{source})") unless node

              fragment(Paren(LParen("("), Statements([node])))
            end

            def hash_expression(source)
              node = parse_expression(source)
              return nil unless node.is_a?(SyntaxTree::HashLiteral)

              fragment(node)
            end

            def class_skeleton_fragment(component_class_name, component_base_class)
              fragment(
                ClassDeclaration(
                  constant_path(component_class_name, declaration: true),
                  constant_path(component_base_class),
                  BodyStmt(
                    Statements([]),
                    nil,
                    nil,
                    nil,
                    nil
                  )
                )
              )
            end

            def constant_path(value, declaration: false)
              parts = to_source(value).split("::")
              raise ArgumentError, "Expected constant path: #{to_source(value).inspect}" if parts.empty? || parts.any?(&:empty?)

              return ConstRef(Const(parts.fetch(0))) if declaration && parts.length == 1
              return VarRef(Const(parts.fetch(0))) if parts.length == 1

              parts.drop(1).reduce(VarRef(Const(parts.fetch(0)))) do |parent, part|
                ConstPathRef(parent, Const(part))
              end
            end

            def source_mark(line_no, source)
              "# #{SourceMap::Mark.new(line_no, source)}"
            end

            def marked_expression(mark, expression)
              source = to_source(expression)

              source_marked_fragment(mark, source, node_for(expression))
            end

            def factory_call(factory:, tag:, children:, props:, mark: nil)
              ast_factory_call(factory: factory, tag: tag, children: children, props: props, mark: mark)
            end

            def script_block(source, body)
              ast_script_block(source, body) || raise(ArgumentError, "Could not build Ruby block from Haml script: #{source.inspect}")
            end

            def silent_script_block(source, body)
              ast_silent_script_block(source, body) || raise(ArgumentError, "Could not build Ruby block from Haml script: #{source.inspect}")
            end

            def silent_script(source)
              ast_silent_script(source) || raise(ArgumentError, "Could not build Ruby begin block from Haml script: #{source.inspect}")
            end

            def branches(branches)
              ast_branches(branches) || raise(ArgumentError, "Could not build Ruby branch from Haml scripts: #{branches.map(&:first).inspect}")
            end

            def silent_branches(branches)
              ast_silent_branches(branches) || raise(ArgumentError, "Could not build Ruby branch from Haml scripts: #{branches.map(&:first).inspect}")
            end

            def ruby_filters(nodes)
              return "" if nodes.empty?

              ast_ruby_filters(nodes) || statements(nodes.map { |node| "begin\n#{indent(node, 2)}\nend" }.join("\n"))
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
                nil_expression
              when 1
                expression = expressions.fetch(0)

                expression.is_a?(Fragment) ? expression : self.expression(to_source(expression))
              else
                node = ArrayLiteral(LBracket("["), Args(expressions.map { |item| argument_node(item) }))

                Fragment.new(format_node(node), node)
              end
            end

            def ast_factory_call(factory:, tag:, children:, props:, mark:)
              factory_node = expression_node(factory)
              arguments = [
                expression_node(tag),
                *children.map { |child| argument_node(child) }
              ]
              return nil if arguments.any?(&:nil?)

              parts = [*arguments, ast_keyword_props(props, mark: mark)].compact

              node = ARef(factory_node, Args(parts))

              Fragment.new(format_node(node), node)
            end

            def ast_silent_script(source)
              statements = parse_statements(source)
              return nil unless statements

              node = ast_begin([*statement_body_for(statements), nil_node])

              Fragment.new(format_node(node), node)
            end

            def ast_script_block(source, body)
              node = block_script_node(source, body)
              return nil unless node

              Fragment.new(format_node(node), node)
            end

            def ast_silent_script_block(source, body)
              node = block_script_node(source, body)
              return nil unless node

              node = ast_begin([node, nil_node])

              Fragment.new(format_node(node), node)
            end

            def ast_branches(branches)
              node = branch_node(branches)
              return nil unless node

              Fragment.new(format_node(node), node)
            end

            def ast_silent_branches(branches)
              node = branch_node(branches)
              return nil unless node

              node = ast_begin([node, nil_node])

              Fragment.new(format_node(node), node)
            end

            def ast_ruby_filters(nodes)
              begins =
                nodes.map do |node|
                  statements =
                    if node.is_a?(Fragment)
                      node
                    else
                      parse_statements(node)
                    end
                  return nil unless statements

                  ast_begin(statement_body_for(statements))
                end

              fragment(Statements(begins))
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

            def body_statement(body)
              BodyStmt(
                Statements(Array(body).flat_map { |statement| statement_body_for(statement) }),
                nil,
                nil,
                nil,
                nil
              )
            end

            def branch_node(branches)
              first_source, first_body = branches.fetch(0)
              if first_source.match?(/\Acase\b/) && nil_fragment?(first_body)
                case_node(first_source, branches.drop(1))
              else
                if_node(branches)
              end
            end

            def if_node(branches)
              source, body = branches.fetch(0)
              return else_node(source, body) if source == "else"

              predicate_source =
                case source
                when /\Aif\s+(.+)\z/ then $1
                when /\Aelsif\s+(.+)\z/ then $1
                else return nil
                end
              predicate = parse_expression(predicate_source)
              return nil unless predicate

              consequent =
                if branches.length > 1
                  if_node(branches.drop(1))
                end

              if source.start_with?("elsif")
                Elsif(predicate, Statements(statement_body_for(body)), consequent)
              else
                IfNode(predicate, Statements(statement_body_for(body)), consequent)
              end
            end

            def else_node(source, body)
              return nil unless source == "else"

              Else(Kw("else"), Statements(statement_body_for(body)))
            end

            def case_node(source, branches)
              value_source = source[/\Acase\s*(.*)\z/, 1]
              return nil unless value_source

              value = value_source.empty? ? nil : parse_expression(value_source)
              consequent = when_node(branches)
              return nil unless consequent

              Case(Kw("case"), value, consequent)
            end

            def when_node(branches)
              source, body = branches.fetch(0)
              return else_node(source, body) if source == "else"
              return nil unless source.start_with?("when ")

              arguments =
                source
                  .delete_prefix("when ")
                  .split(",")
                  .map { |argument| parse_expression(argument.strip) }
              return nil if arguments.any?(&:nil?)

              consequent =
                if branches.length > 1
                  when_node(branches.drop(1))
                end

              When(Args(arguments), Statements(statement_body_for(body)), consequent)
            end

            def block_script_node(source, body)
              match = source.match(/\A(?<call>.+?)\s+do(?:\s*\|(?<parameters>[^|]*)\|)?\s*\z/)
              return nil unless match

              call_node = parse_expression(match[:call])
              return nil unless call_node

              MethodAddBlock(
                call_node,
                BlockNode(
                  Kw("do"),
                  block_parameters(match[:parameters]),
                  body_statement(body)
                )
              )
            end

            def block_parameters(source)
              return nil if source.nil?

              parameters =
                source
                  .split(",")
                  .map(&:strip)
                  .reject(&:empty?)
                  .map { |parameter| Ident(parameter) }

              BlockVar(Params(parameters, [], nil, [], [], nil, nil), [])
            end

            def ast_keyword_props(props, mark:)
              return nil if props.empty?

              AssocSplat(
                HashLiteral(
                  LBrace("{"),
                  props.map { |name, value| Assoc(Label("#{name}:"), argument_node(value, mark: mark)) }
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
              case value
              when String
                if value.match?(/\\|#[@${]/)
                  expression_node(value.inspect)
                else
                  StringLiteral([TStringContent(value)], "\"")
                end
              when Integer
                Int(value.to_s)
              when Float
                FloatLiteral(value.to_s)
              when true
                VarRef(Kw("true"))
              when false
                VarRef(Kw("false"))
              when nil
                nil_node
              else
                expression_node(value.inspect)
              end
            end

            def freeze_node(node)
              CallNode(node, Period("."), Ident("freeze"), nil)
            end

            def nil_node
              VarRef(Kw("nil"))
            end

            def symbol_node(value)
              if value.match?(/\A[a-zA-Z_]\w*[!?=]?\z/)
                SymbolLiteral(Ident(value))
              else
                DynaSymbol([TStringContent(value)], ":\"")
              end
            end

            def source_marked_fragment(mark, source, node)
              marked_source = "#{mark}\n#{source}"
              return Fragment.new(marked_source, nil) unless node

              node = Statements([comment_node(mark), node])

              Fragment.new(format_node(node), node)
            end

            def comment_node(value)
              Comment(value, false)
            end

            def nil_fragment?(value)
              value.is_a?(Fragment) && value.node.is_a?(SyntaxTree::VarRef) && to_source(value) == "nil"
            end

            def node_for(value)
              return value.node if value.is_a?(Fragment)

              parse_expression(to_source(value))
            end

            def argument_node(value, mark: nil)
              fragment = expression_fragment(value)
              statements = []
              statements << comment_node(mark) if mark

              if fragment.node.is_a?(SyntaxTree::Statements)
                statements.concat(fragment.node.body)
              elsif mark
                node = node_for(fragment)
                return nil unless node

                statements << node
              else
                return node_for(fragment)
              end

              ast_begin(statements)
            end

            def statement_body_for(value)
              return value.statement_body if value.is_a?(Fragment)

              value.is_a?(SyntaxTree::Statements) ? value.body : [value].compact
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
            translations_source:,
            styleable: false
          )
            component_base_class = ConstPath.parse(component_base_class, name: "component_base_class")
            factory = ConstPath.parse(factory, name: "factory")
            builder = RubyBuilder.new
            template = compile_template(source, factory: factory, styleable: styleable, builder: builder)
            ast =
              builder.component_program(
                component_class_name: component_class_name,
                component_base_class: component_base_class,
                translations_source: translations_source,
                ruby_source: template.ruby,
                render_source: template.render,
                styles_source: styles_source
              )
            HamlTransformResult.from_ast(
              ast,
              source: source,
              metadata: {source: source, module_id: module_id}
            )
          end

          private

          Template = Data.define(:ruby, :render)
          RubyLine = Data.define(:line_no, :source)

          def compile_template(source, factory:, builder:, styleable: false)
            parsed = SyntaxTree::Haml.parse(source)
            render_nodes = parsed.children.reject { |node| ruby_filter?(node) || css_filter?(node) }
            ruby_nodes = parsed.children.select { |node| ruby_filter?(node) }
            ruby = compile_ruby_filters(ruby_nodes, builder: builder)
            render = compile_nodes(render_nodes, factory: factory, styleable: styleable, builder: builder)

            Template.new(ruby, render)
          end

          def compile_nodes(nodes, factory:, builder:, styleable: false)
            builder.expressions(compile_node_expressions(nodes, factory: factory, styleable: styleable, builder: builder))
          end

          def compile_node_expressions(nodes, factory:, builder:, styleable: false)
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

                expressions << compile_script_group(group, factory: factory, styleable: styleable, builder: builder)
              else
                expression = compile_node(node, factory: factory, styleable: styleable, builder: builder)
                expression.is_a?(Array) ? expressions.concat(expression) : expressions << expression
                index += 1
              end
            end

            expressions
          end

          def compile_node(node, factory:, builder:, styleable: false)
            mark = source_mark(node, builder: builder)
            expression =
              case node.type
              when :tag
                tag = builder.marked_expression(mark, compile_tag(node, factory: factory, styleable: styleable, builder: builder))
                spaced_tag_expressions(node, tag, builder: builder)
              when :plain
                builder.literal(node.value.fetch(:text))
              when :script
                compile_script(node, factory: factory, styleable: styleable, builder: builder)
              when :silent_script
                compile_silent_script(node, factory: factory, styleable: styleable, builder: builder)
              when :filter
                compile_filter_node(node, builder: builder)
              end

            return expression if node.type == :tag

            builder.marked_expression(mark, expression)
          end

          def compile_script_group(nodes, factory:, builder:, styleable: false)
            return compile_script_branch(nodes.fetch(0), factory: factory, styleable: styleable, builder: builder) if nodes.length == 1 && branch_start?(nodes.fetch(0))
            return compile_node(nodes.fetch(0), factory: factory, styleable: styleable, builder: builder) if nodes.length == 1

            compile_branches(
              nodes.map { |node| [script_source(node), node.children] },
              factory: factory,
              styleable: styleable,
              builder: builder
            )
          end

          def compile_script(node, factory:, builder:, styleable: false)
            source = script_source(node)
            return builder.parenthesized_expression(source) if node.children.empty?

            builder.script_block(source, compile_nodes(node.children, factory: factory, styleable: styleable, builder: builder))
          end

          def compile_script_branch(node, factory:, builder:, styleable: false)
            compile_branches([[script_source(node), node.children]], factory: factory, styleable: styleable, builder: builder)
          end

          def compile_silent_script(node, factory:, builder:, styleable: false)
            source = script_source(node)
            return builder.silent_script(source) if node.children.empty?
            if block_script?(source)
              return builder.silent_script_block(
                source,
                compile_nodes(node.children, factory: factory, styleable: styleable, builder: builder)
              )
            end

            compile_silent_branches(split_silent_script_branches(node), factory: factory, styleable: styleable, builder: builder)
          end

          def compile_branches(branches, factory:, builder:, styleable: false)
            builder.branches(
              branches.map do |source, children|
                [source, compile_nodes(children, factory: factory, styleable: styleable, builder: builder)]
              end
            )
          end

          def compile_silent_branches(branches, factory:, builder:, styleable: false)
            builder.silent_branches(
              branches.map do |source, children|
                [source, compile_nodes(children, factory: factory, styleable: styleable, builder: builder)]
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

          def branch_start?(node)
            node.type == :script && %w[if unless case begin].include?(node.value.fetch(:keyword))
          end

          def block_script?(source)
            source.match?(/\s+do(?:\s*\|[^|]*\|)?\s*\z/)
          end

          def compile_tag(node, factory:, builder:, styleable: false)
            children = []
            value = node.value.fetch(:value)
            if value && !value.empty?
              children << (node.value.fetch(:parse) ? builder.parenthesized_expression(value) : builder.literal(value))
            end
            children.concat(compile_node_expressions(node.children, factory: factory, styleable: styleable, builder: builder))

            compile_factory_call(node, children, factory: factory, styleable: styleable, builder: builder)
          end

          def spaced_tag_expressions(node, tag, builder:)
            expressions = []
            expressions << builder.literal(" ") if node.value.fetch(:nuke_inner_whitespace)
            expressions << tag
            expressions << builder.literal(" ") if node.value.fetch(:nuke_outer_whitespace)
            expressions
          end

          def compile_factory_call(node, children, factory:, builder:, styleable: false)
            builder.factory_call(
              factory: factory,
              tag: compile_tag_name(node, builder: builder),
              children: children,
              props: attributes(node, styleable: styleable, builder: builder),
              mark: source_mark(node, builder: builder)
            )
          end

          def compile_tag_name(node, builder:)
            tag_name = node.value.fetch(:name)
            tag_name.match?(/\A[A-Z]/) ? builder.expression(tag_name) : builder.symbol(tag_name)
          end

          def attributes(node, builder:, styleable: false)
            dynamic = dynamic_attributes(node, builder: builder)

            static_attributes(node, builder: builder)
              .merge(dynamic)
              .merge(object_ref_attributes(node, builder: builder))
              .merge(class_attributes(node, dynamic_attributes: dynamic, styleable: styleable, builder: builder))
          end

          def compile_ruby_filters(nodes, builder:)
            builder.ruby_filters(nodes.map { |node| compile_ruby_filter(node, builder: builder) })
          end

          def compile_ruby_filter(node, builder:)
            source =
              node.value.fetch(:text)
                .lines
                .map
                .with_index(node.line + 1) do |line, line_no|
                  "#{source_mark(RubyLine.new(line_no, line.strip), builder: builder)}\n#{line.chomp}"
                end
                .join("\n")

            builder.statements(source)
          end

          def compile_filter_node(node, builder:)
            raise ArgumentError, "Only :ruby Haml filters are supported" unless ruby_filter?(node)

            builder.literal(node.value.fetch(:text))
          end

          def ruby_filter?(node)
            node.type == :filter && node.value.fetch(:name) == "ruby"
          end

          def css_filter?(node)
            node.type == :filter && node.value.fetch(:name) == "css"
          end

          def static_attributes(node, builder:)
            node
              .value
              .fetch(:attributes)
              .except("class")
              .to_h { |key, value| [key.to_sym, builder.literal(value)] }
          end

          def dynamic_attributes(node, builder:)
            source = node.value.fetch(:dynamic_attributes).old
            return {} unless source

            hash = builder.hash_expression(source)
            return {} unless hash

            hash.node.assocs.to_h do |assoc|
              [attribute_key(assoc.key, builder: builder), builder.fragment(assoc.value)]
            end
          end

          def class_attributes(node, dynamic_attributes:, builder:, styleable: false)
            static_classes = static_class_lookups(node, builder: builder)
            dynamic_class = dynamic_attributes[:class]
            return dynamic_class ? {class: dynamic_class} : {} unless styleable || !static_classes.empty?

            values = [
              (tag_class_lookup(node, builder: builder) if styleable),
              *static_classes,
              dynamic_class
            ].compact
            return {} if values.empty?

            {class: builder.expression("Klenod::Runtime.class_names(#{values.map(&:source).join(", ")})")}
          end

          def tag_class_lookup(node, builder:)
            tag_name = node.value.fetch(:name)
            return nil if tag_name.match?(/\A[A-Z]/)

            builder.expression("Styles[#{builder.symbol("__#{tag_name}").source}]")
          end

          def static_class_lookups(node, builder:)
            node
              .value
              .fetch(:attributes)
              .fetch("class", "")
              .split
              .map { |class_name| builder.expression("Styles[#{builder.symbol(class_name).source}] || #{class_name.inspect}") }
          end

          def object_ref_attributes(node, builder:)
            source = node.value.fetch(:object_ref)
            return {} unless source.is_a?(String)

            expression = builder.expression(source)
            key =
              if expression.node.is_a?(SyntaxTree::ArrayLiteral) && expression.node.contents&.parts&.length == 1
                builder.fragment(expression.node.contents.parts.fetch(0))
              else
                expression
              end

            {key: key}
          end

          def attribute_key(node, builder:)
            case node
            when SyntaxTree::Label
              node.value.delete_suffix(":").to_sym
            else
              builder.fragment(node).source.to_sym
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
          style_dependencies = []
          builder = DefaultTransformer::RubyBuilder.new
          context.unregister_virtual_modules(module_id)

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
            style_dependencies << dependency
          end
          inline_css_sources(code).each_with_index do |source, index|
            virtual_module_id = ModuleId.new("#{module_id.path}.inline.#{index}.css", nil)
            context.register_virtual_module(virtual_module_id, source, owner_id: module_id)
            dependency =
              Dependency
                .create(
                  specifier: virtual_module_id.to_s,
                  importer_id: module_id,
                  kind: :inline_style,
                  metadata: {virtual_module_id: virtual_module_id}
                )
                .with(id: "#{module_id}:inline_style:#{index}")
            dependencies << dependency
            style_dependencies << dependency
          end
          styles_source = styles_source_for(builder, style_dependencies)
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
              translations_source: translations_source,
              styleable: !style_dependencies.empty?
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

        def runtime_import_value(_resolved_dependency, record, _context)
          return Runtime::DefaultImport.new(:Default) if record.id.extname == ".haml"

          super
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

        def inline_css_sources(source)
          SyntaxTree::Haml
            .parse(source)
            .children
            .select { |node| node.type == :filter && node.value.fetch(:name) == "css" }
            .map { |node| node.value.fetch(:text) }
        end

        def styles_source_for(builder, dependencies)
          imports = dependencies.map { |dependency| builder.import_call(dependency.id) }
          return builder.frozen_literal({}).source if imports.empty?
          return imports.fetch(0).source if imports.length == 1

          builder
            .expression(
              "[#{imports.map(&:source).join(", ")}].reduce({}) do |classes, styles|\n" \
                "  classes.merge(styles) { |_name, *class_names| class_names.join(\" \") }\n" \
                "end.freeze"
            )
            .source
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
