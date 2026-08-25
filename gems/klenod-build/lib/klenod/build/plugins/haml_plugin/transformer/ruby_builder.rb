# frozen_string_literal: true

require "ripper"
require "syntax_tree"
require "syntax_tree/dsl"
require "syntax_suggest/api"
require "syntax_suggest/explain_syntax"

module Klenod
  module Build
    module Plugins
      module HamlPlugin
        class Transformer
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

            def initialize(profiler: nil, global_variables: nil)
              @profiler = profiler
              @global_variables = global_variables
              @expression_cache = {}
              @statements_cache = {}
              @program_cache = {}
              @literal_cache = {}
            end

            def component_source(
              component_class_name:,
              component_base_class:,
              translations_source:,
              ruby_source:,
              render_source:,
              styles_source:,
              haml_helper_source: nil,
              static_constants: [],
              i18n_source: nil
            )
              component_program(
                component_class_name: component_class_name,
                component_base_class: component_base_class,
                translations_source: translations_source,
                i18n_source: i18n_source,
                ruby_source: ruby_source,
                render_source: render_source,
                styles_source: styles_source,
                haml_helper_source: haml_helper_source,
                static_constants: static_constants
              ).source
            end

            def component_program(
              component_class_name:,
              component_base_class:,
              translations_source:,
              ruby_source:,
              render_source:,
              styles_source:,
              haml_helper_source: nil,
              static_constants: [],
              i18n_source: nil
            )
              component_class_name = expression_fragment(component_class_name)
              component_base_class = expression_fragment(component_base_class)
              translations_source = expression_fragment(translations_source)
              ruby_source = statements_fragment(ruby_source)
              render_source = expression_fragment(render_source)
              styles_source = expression_fragment(styles_source)
              haml_helper_source = statements_fragment(haml_helper_source) if haml_helper_source

              header = [
                Fragment.new("# frozen_string_literal: true", comment_node("# frozen_string_literal: true")),
                constant_assignment(
                  "KlenodImport",
                  call(receiver: nil, name: "method", arguments: [symbol("__klenod_import__")])
                ),
                haml_helper_source
              ].compact
              component_class =
                component_class_fragment(
                  component_class_name: component_class_name,
                  component_base_class: component_base_class,
                  translations_source: translations_source,
                  styles_source: styles_source,
                  i18n_source: i18n_source,
                  ruby_source: ruby_source,
                  render_source: render_source,
                  static_constants: static_constants
                )
              footer = [
                constant_assignment("Default", component_class_name),
                constant_assignment("ClassNames", "Default::ClassNames"),
                constant_assignment("Translations", "Default::Translations")
              ]

              program_from_fragments(header, component_class, footer)
            end

            def component_class_fragment(
              component_class_name:,
              component_base_class:,
              translations_source:,
              styles_source:,
              ruby_source:,
              render_source:,
              static_constants: [],
              i18n_source: nil
            )
              skeleton = class_skeleton_fragment(component_class_name, component_base_class)
              body_fragments =
                [
                  method_definition("module_path", target: "self", body: file_expression),
                  constant_assignment("Self", "self"),
                  constant_assignment("Translations", translations_source),
                  i18n_source,
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
                  constant_assignment("ClassNames", styles_source),
                  ruby_source,
                  *static_constants,
                  public_method_definition("render", body: render_source)
                ]
              body =
                body_fragments.flat_map { |fragment| statement_body_for(fragment) }

              Fragment.new(
                [
                  "class #{to_source(component_class_name)} < #{to_source(component_base_class)}",
                  indent(compact_join(body_fragments), 2),
                  "end"
                ].join("\n"),
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
              source_expressions(expressions)
            end

            def expression(source, line_no: nil)
              source = rewrite_ruby_source(source, line_no)
              return Fragment.new(source, constant_path(source)) if source.match?(VALID_CONST_PATH)

              node = parse_expression(source, context: :expression)

              Fragment.new(source, node)
            end

            def statements(source, line_no: nil)
              source = rewrite_ruby_source(source, line_no)
              node = parse_statements(source)

              Fragment.new(source, node)
            end

            def program(source)
              node = parse_program(source)

              Fragment.new(node ? format_node(node) : source, node)
            end

            def program_from_fragments(*fragments)
              fragments = fragments.flatten
              body = fragments.flat_map { |fragment| statement_body_for(fragment) }

              Fragment.new(compact_join(fragments), Program(Statements(body)))
            end

            def fragment(node)
              Fragment.new(format_node(node), node)
            end

            def node_fragment(source, node)
              Fragment.new(source.to_s, node)
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
              if value.is_a?(String) && value.length <= 1
                return @literal_cache[value] ||= literal_fragment(value)
              end

              literal_fragment(value)
            end

            def literal_fragment(value)
              Fragment.new(literal_source(value), literal_node(value))
            end

            def frozen_literal(value)
              fragment(frozen_literal_node(value))
            end

            def import_call(dependency_id)
              Fragment.new(
                "__klenod_import__(#{literal_source(dependency_id)})",
                CallNode(
                  nil,
                  nil,
                  Ident("__klenod_import__"),
                  ArgParen(Args([literal_node(dependency_id)]))
                )
              )
            end

            def constant_assignment(name, value)
              value = expression_fragment(value)
              node = Assign(VarField(Const(name.to_s)), node_for(value))
              Fragment.new("#{name} = #{to_source(value)}", node)
            end

            def call(receiver:, name:, arguments:)
              receiver = expression_fragment(receiver) unless receiver.nil?
              arguments = arguments.map { |argument| expression_fragment(argument) }
              receiver_node = receiver.nil? ? nil : node_for(receiver)

              node =
                CallNode(
                  receiver_node,
                  receiver_node ? Period(".") : nil,
                  Ident(name.to_s),
                  ArgParen(Args(arguments.map { |argument| node_for(argument) }))
                )
              receiver_prefix = receiver ? "#{to_source(receiver)}." : nil
              source = "#{receiver_prefix}#{name}(#{arguments.map { |argument| to_source(argument) }.join(", ")})"
              Fragment.new(source, node)
            end

            def method_definition(name, body:, target: nil, parameters: [])
              body = Array(body)
              body_source = compact_join(body)
              node =
                DefNode(
                  target && node_for(expression_fragment(target)),
                  target ? Period(".") : nil,
                  Ident(name.to_s),
                  Params(parameters.map { |parameter| Ident(parameter.to_s) }, [], nil, [], [], nil, nil),
                  body_statement(body)
                )
              target_source = target ? "#{to_source(expression_fragment(target))}." : ""
              params_source = parameters.empty? ? "" : "(#{parameters.join(", ")})"
              source = ["def #{target_source}#{name}#{params_source}", indent(body_source, 2), "end"].join("\n")
              Fragment.new(source, node)
            end

            def public_method_definition(name, body:, parameters: [])
              method = method_definition(name, parameters: parameters, body: body)
              node =
                Command(
                  Ident("public"),
                  Args([method.node]),
                  nil
                )
              Fragment.new("public #{method.source}", node)
            end

            def nil_expression
              Fragment.new("nil", nil_node)
            end

            def file_expression
              Fragment.new("__FILE__", VarRef(Kw("__FILE__")))
            end

            def symbol(value)
              value = value.to_s
              Fragment.new(symbol_source(value), symbol_node(value))
            end

            def symbol_fragment(value)
              Fragment.new(symbol_source(value.to_s), nil)
            end

            def styles_lookup(name)
              name = name.to_s

              Fragment.new(
                "ClassNames[#{symbol_source(name)}]",
                ARef(VarRef(Const("ClassNames")), Args([symbol_node(name)]))
              )
            end

            def class_name_lookup(name)
              name = name.to_s

              Fragment.new(
                "ClassNames[#{symbol_source(name)}]",
                ARef(VarRef(Const("ClassNames")), Args([symbol_node(name)]))
              )
            end

            def class_names(values)
              fragments = values.map { |value| expression_fragment(value) }

              Fragment.new(
                "ClassNames.class_name(#{fragments.map(&:source).join(", ")})",
                CallNode(
                  constant_path("ClassNames"),
                  Period("."),
                  Ident("class_name"),
                  ArgParen(Args(fragments.map { |fragment| node_for(fragment) }))
                )
              )
            end

            def scoped_class_name(values)
              fragments = values.map { |value| expression_fragment(value) }

              Fragment.new(
                "ClassNames.class_name(#{fragments.map(&:source).join(", ")})",
                nil
              )
            end

            def parenthesized_expression(source, line_no: nil)
              source = rewrite_ruby_source(source, line_no)
              node = parse_expression(source, context: :parenthesized_expression)
              return expression("(#{source})") unless node

              fragment(Paren(LParen("("), Statements([node])))
            end

            def hash_expression(source, line_no: nil)
              source = rewrite_ruby_source(source, line_no)
              node = parse_expression(source, context: :hash_expression)
              return nil unless node.is_a?(SyntaxTree::HashLiteral)

              Fragment.new(source, node)
            end

            def class_skeleton_fragment(component_class_name, component_base_class)
              Fragment.new(
                "",
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

            def source_mark(line_no, _source)
              "# #{Runtime::SourceMap::MARK_PREFIX}:#{line_no}"
            end

            def marked_expression(mark, expression)
              source = to_source(expression)

              source_marked_fragment(mark, source, node_for(expression))
            end

            def factory_call(factory:, tag:, children:, props:, mark: nil)
              source_factory_call(factory: factory, tag: tag, children: children, props: props, mark: mark)
            end

            def slot_call(name:, fallback:)
              arguments = ["self", name ? argument_source(name) : "nil"]
              arguments << argument_source(fallback) if fallback
              expression("HamlHelper.render_slot(#{arguments.join(", ")})")
            end

            def freeze_static(value)
              expression("HamlHelper.freeze_static(#{argument_source(value)})")
            end

            def script_block(source, body, line_no: nil)
              source = rewrite_ruby_source(source, nil)
              ast_script_block(source, body) || raise_ruby_parse_error(source, line_no: line_no, context: "Could not build Ruby block from Haml script")
            end

            def silent_script_block(source, body, line_no: nil)
              source = rewrite_ruby_source(source, nil)
              ast_silent_script_block(source, body) || raise_ruby_parse_error(source, line_no: line_no, context: "Could not build Ruby block from Haml script")
            end

            def silent_script(source)
              source = rewrite_ruby_source(source, nil)
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

            def render_ruby_filter(node)
              source = to_source(node)
              parsed = (node if node.is_a?(Fragment) && node.node?) || statements(source)
              return statements("begin\n#{indent(source, 2)}\n  nil\nend") unless parsed

              fragment(
                ast_begin([
                  *statement_body_for(parsed),
                  nil_node
                ])
              )
            rescue SyntaxTree::Parser::ParseError
              statements("begin\n#{indent(source, 2)}\n  nil\nend")
            end

            def format_node(node)
              if @profiler
                @profiler.measure(:haml_format_node, node: node.class.name) do
                  SyntaxTree::Formatter.format(+"", node, 0)
                end
              else
                SyntaxTree::Formatter.format(+"", node, 0)
              end
            end

            def indent(value, spaces)
              to_source(value).lines.map { |line| "#{" " * spaces}#{line}" }.join
            end

            def compact_join(fragments)
              Array(fragments)
                .map { |fragment| to_source(fragment).to_s }
                .reject(&:empty?)
                .join("\n")
            end

            def line_rewritten_source(source, line_no)
              rewrite_ruby_source(source, line_no)
            end

            def ruby_parse_error(source, line_no:, context:)
              raise_ruby_parse_error(source, line_no: line_no, context: context)
            end

            def block_script?(source)
              fixed_source = fix_syntax_by_adding_missing_pairs(source)
              node = parse_expression(fixed_source, context: :block_script_predicate)

              node.is_a?(SyntaxTree::MethodAddBlock)
            end

            private

            def rewrite_ruby_source(source, line_no)
              source = rewrite_line_constant(source, line_no)
              rewrite_global_variables(source)
            end

            def rewrite_line_constant(source, line_no)
              return source.to_s unless line_no

              source = source.to_s
              return source unless source.include?("__LINE__")

              line_offsets = [0]
              source.each_line(chomp: false) { |line| line_offsets << line_offsets.last + line.length }

              Ripper
                .lex(source)
                .select { |(_line, _column), type, token, _state| type == :on_kw && token == "__LINE__" }
                .reverse_each
                .each_with_object(source.dup) do |((line, column), _type, token, _state), rewritten|
                  offset = line_offsets.fetch(line - 1) + column
                  rewritten[offset, token.length] = line_no.to_s
                end
            end

            def rewrite_global_variables(source)
              return source unless @global_variables

              line_offsets = [0]
              source.each_line(chomp: false) { |line| line_offsets << line_offsets.last + line.length }

              Ripper
                .lex(source)
                .select { |(_line, _column), type, token, _state| type == :on_gvar && prop_global_variable?(token) }
                .reverse_each
                .each_with_object(source.dup) do |((line, column), _type, token, _state), rewritten|
                  name = token.delete_prefix("$")
                  offset = line_offsets.fetch(line - 1) + column
                  rewritten[offset, token.length] = "#{@global_variables}[#{symbol_source(name)}]"
                end
            end

            def prop_global_variable?(token)
              token.match?(/\A\$[a-z]\w*\z/)
            end

            def source_expressions(expressions)
              case expressions.length
              when 0
                nil_expression
              when 1
                expression = expressions.fetch(0)

                expression.is_a?(Fragment) ? expression : self.expression(to_source(expression))
              else
                Fragment.new("[#{expressions.map { |item| argument_source(item) }.join(", ")}]", nil)
              end
            end

            def source_factory_call(factory:, tag:, children:, props:, mark:)
              factory = expression_fragment(factory)
              tag = expression_fragment(tag)
              children = children.map { |child| expression_fragment(child) }

              source_parts = [
                to_source(tag),
                *children.map { |child| argument_source(child) },
                *keyword_props_source(props, mark: mark)
              ].compact
              Fragment.new("#{to_source(factory)}[#{source_parts.join(", ")}]", nil)
            end

            def ast_silent_script(source)
              statements = parse_statements(source)
              return nil unless statements

              node = ast_begin([*statement_body_for(statements), nil_node])

              Fragment.new(["begin", indent(source, 2), "  nil", "end"].join("\n"), node)
            end

            def ast_script_block(source, body)
              node = block_script_node(source, body)
              return nil unless node

              Fragment.new(block_source(source, body), node)
            end

            def ast_silent_script_block(source, body)
              node = block_script_node(source, body)
              return nil unless node

              node = ast_begin([node, nil_node])

              Fragment.new(["begin", indent(block_source(source, body), 2), "  nil", "end"].join("\n"), node)
            end

            def ast_branches(branches)
              node = branch_node(branches)
              return nil unless node

              Fragment.new(branch_source(branches), node)
            end

            def ast_silent_branches(branches)
              node = branch_node(branches)
              return nil unless node

              node = ast_begin([node, nil_node])

              Fragment.new(["begin", indent(branch_source(branches), 2), "  nil", "end"].join("\n"), node)
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

              source = nodes.map { |node| ["begin", indent(to_source(node), 2), "end"].join("\n") }.join("\n")

              Fragment.new(source, Statements(begins))
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

            def block_source(source, body)
              body_source = to_source(body)

              if source.include?("{")
                "#{source} #{body_source} }"
              else
                [source, indent(body_source, 2), "end"].join("\n")
              end
            end

            def branch_source(branches)
              body =
                branches
                  .map do |source, body|
                    if source == "else"
                      ["else", indent(to_source(body), 2)].join("\n")
                    else
                      [source, indent(to_source(body), 2)].join("\n")
                    end
                  end
                  .join("\n")

              "#{body}\nend"
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
              predicate = parse_expression(predicate_source, context: :branch_predicate)
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

              value = value_source.empty? ? nil : parse_expression(value_source, context: :case_value)
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
                  .map { |argument| parse_expression(argument.strip, context: :when_argument) }
              return nil if arguments.any?(&:nil?)

              consequent =
                if branches.length > 1
                  when_node(branches.drop(1))
                end

              When(Args(arguments), Statements(statement_body_for(body)), consequent)
            end

            def block_script_node(source, body)
              node = parse_expression(fix_syntax_by_adding_missing_pairs(source), context: :block_script)
              return nil unless node.is_a?(SyntaxTree::MethodAddBlock)

              MethodAddBlock(
                node.call,
                SyntaxTree::BlockNode.new(
                  opening: node.block.opening,
                  block_var: node.block.block_var,
                  bodystmt: block_body_for(node.block, body),
                  location: node.block.location
                )
              )
            end

            def block_body_for(block, body)
              statements = Statements(Array(body).flat_map { |statement| statement_body_for(statement) })

              block.opening.is_a?(SyntaxTree::LBrace) ? statements : body_statement(body)
            end

            def ast_keyword_props(props, mark:)
              return nil if props.empty?

              AssocSplat(
                HashLiteral(
                  LBrace("{"),
                  props.map { |name, value| Assoc(prop_key_node(name), argument_node(value, mark: mark)) }
                )
              )
            end

            def keyword_props_source(props, mark:)
              return [] if props.empty?

              props.map do |name, value|
                "#{prop_key_source(name)} #{argument_source(value, mark: mark)}"
              end
            end

            def prop_key_source(name)
              name = name.to_s
              return "#{name}:" if name.match?(/\A[a-zA-Z_]\w*\z/)

              "#{symbol_source(name)} =>"
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

            def literal_source(value)
              case value
              when String
                value.inspect
              when Integer, Float
                value.to_s
              when true
                "true"
              when false
                "false"
              when nil
                "nil"
              else
                value.inspect
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

            def symbol_source(value)
              if value.match?(/\A[a-zA-Z_]\w*[!?=]?\z/)
                ":#{value}"
              else
                ":#{value.inspect}"
              end
            end

            def prop_key_node(name)
              name = name.to_s
              return Label("#{name}:") if name.match?(/\A[a-zA-Z_]\w*\z/)

              symbol_node(name)
            end

            def source_marked_fragment(mark, source, node)
              marked_source = "#{mark}\n#{source}"
              return Fragment.new(marked_source, nil) unless node

              node = Statements([comment_node(mark), node])

              Fragment.new(marked_source, node)
            end

            def comment_node(value)
              Comment(value, false)
            end

            def nil_fragment?(value)
              value.is_a?(Fragment) && value.node.is_a?(SyntaxTree::VarRef) && to_source(value) == "nil"
            end

            def node_for(value)
              return value.node if value.is_a?(Fragment)

              parse_expression(to_source(value), context: :node_for)
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

            def argument_source(value, mark: nil)
              fragment = expression_fragment(value)
              source = to_source(fragment)

              if mark
                source = "#{mark}\n#{source}"
              end

              if fragment.node.is_a?(SyntaxTree::Statements) || mark || (source.include?("\n") && !multiline_argument_expression?(source))
                ["begin", indent(source, 2), "end"].join("\n")
              else
                source
              end
            end

            def multiline_argument_expression?(source)
              source.start_with?("if ", "unless ", "case", "begin")
            end

            def statement_body_for(value)
              return value.statement_body if value.is_a?(Fragment)

              value.is_a?(SyntaxTree::Statements) ? value.body : [value].compact
            end

            def expression_node(source)
              source = source.to_s
              return constant_path(source) if source.match?(VALID_CONST_PATH)

              parse_expression(source, context: :expression_node) || raise(ArgumentError, "Could not parse Ruby expression: #{source.inspect}")
            end

            def parse_expression(source, context:)
              cached_parse(@expression_cache, source, :"haml_parse_expression:#{context}") do
                SyntaxTree
                  .parse(source)
                  &.statements
                  &.body
                  &.find { |node| !node.instance_of?(SyntaxTree::Comment) }
              end
            rescue SyntaxTree::Parser::ParseError
              nil
            end

            def parse_statements(source)
              cached_parse(@statements_cache, source, :haml_parse_statements) { SyntaxTree.parse(source)&.statements }
            rescue SyntaxTree::Parser::ParseError
              nil
            end

            def parse_program(source)
              cached_parse(@program_cache, source, :haml_parse_program) { SyntaxTree.parse(source) }
            rescue SyntaxTree::Parser::ParseError
              nil
            end

            def cached_parse(cache, source, event_name)
              source = source.to_s
              return cache.fetch(source) if cache.key?(source)

              cache[source] =
                if @profiler
                  @profiler.measure(event_name) { yield }
                else
                  yield
                end
            end

            def fix_syntax_by_adding_missing_pairs(source)
              left_right = SyntaxSuggest::LeftRightLexCount.new
              SyntaxSuggest::LexAll.new(source: source).each { |lex| left_right.count_lex(lex) }

              [source, *left_right.missing].join("\n")
            end

            def raise_ruby_parse_error(source, line_no:, context:)
              parse_error = syntax_tree_parse_error(source)
              explain =
                SyntaxSuggest::ExplainSyntax.new(
                  code_lines: SyntaxSuggest::CodeLine.from_source(source)
                ).call
              errors = explain.errors
              missing = explain.missing.map { |item| explain.why(item) } - errors

              message = [context]
              message << "Errors:\n  #{errors.join("\n  ")}" unless errors.empty?
              message << "Missing:\n  #{missing.join("\n  ")}" unless missing.empty?

              raise RubyParseError.new(message.join("\n\n"), line: source_line_for_parse_error(line_no, parse_error))
            end

            def syntax_tree_parse_error(source)
              SyntaxTree.parse(source)
              nil
            rescue SyntaxTree::Parser::ParseError => error
              error
            end

            def source_line_for_parse_error(line_no, parse_error)
              return line_no unless line_no && parse_error&.lineno

              line_no + parse_error.lineno - 1
            end
          end
        end
      end
    end
  end
end
