# frozen_string_literal: true

require "ripper"
require "syntax_tree"
require "syntax_tree/dsl"
require "syntax_tree/haml"
require "syntax_suggest/api"
require "syntax_suggest/explain_syntax"

require "klenod/runtime/source_map"
require_relative "../plugin"
require_relative "../dependency"
require_relative "../module_id"
require_relative "../ruby_import_rewriter"
require_relative "../transform_result"
require_relative "../watched_pattern"
require_relative "intl_plugin"
require_relative "markdown_compiler"
require_relative "class_names_runtime"

module Klenod
  module Build
    module Plugins
      class HamlPlugin < Plugin
        include ClassNamesRuntime

        class ParseError < StandardError
          attr_reader :module_id, :source, :line, :column, :cause

          def initialize(error, source:, module_id:)
            @cause = error
            @module_id = module_id
            @source = source
            @line = source_line_for(error)
            @column = nil

            super(message_for(error))
            set_backtrace(error.backtrace)
          end

          private

          def source_line_for(error)
            line = error.line if error.respond_to?(:line)
            line ||= full_message_line_for(error)
            return nil unless line.is_a?(Integer)

            # Haml reports zero-based line indexes.
            error_line_zero_based?(error) ? line + 1 : line
          end

          def full_message_line_for(error)
            return nil unless error.respond_to?(:full_message)

            error.full_message(highlight: false, order: :top).match(/\A\(haml\):(?<line>\d+):/) { it[:line].to_i }
          end

          def error_line_zero_based?(error)
            error.respond_to?(:line) && error.line.is_a?(Integer) && !error.is_a?(RubyParseError)
          end

          def message_for(error)
            location =
              if module_id && line
                "#{module_id}:#{line}"
              elsif module_id
                module_id.to_s
              elsif line
                "line #{line}"
              end

            title = location ? "#{location}: Haml parse error" : "Haml parse error"

            [
              title,
              error.message,
              source_excerpt
            ].compact.join("\n\n")
          end

          def source_excerpt
            return nil unless line

            lines = source.lines
            return nil if lines.empty?

            index = line - 1
            first = [index - 2, 0].max
            last = [index + 2, lines.length - 1].min
            width = (last + 1).to_s.length
            excerpt =
              (first..last).map do |line_index|
                marker = (line_index == index) ? ">" : " "
                number = (line_index + 1).to_s.rjust(width)
                formatted = "#{marker} #{number} | #{lines.fetch(line_index).chomp}"
                if marker == ">"
                  "\e[1;31m#{formatted}\e[0m"
                else
                  formatted
                end
              end

            "Source:\n#{excerpt.join("\n")}"
          end
        end

        class RubyParseError < StandardError
          attr_reader :line

          def initialize(message, line: nil)
            @line = line

            super(message)
          end
        end

        HamlTransformResult = Data.define(:code, :source_map, :metadata, :ast) do
          def self.from_ast(ast, source:, metadata:)
            code = ast.source

            new(
              code,
              Runtime::SourceMap::SourceMap.parse(source, code),
              metadata,
              ast
            )
          end
        end

        DEFAULT_COMPONENT_BASE_CLASS = "Object"
        DEFAULT_FACTORY = "Object"
        HAML_HELPER_SPECIFIER = "virtual:klenod/haml_helper"
        HAML_HELPER_MODULE_ID = ModuleId.new("#{HAML_HELPER_SPECIFIER}.rb", nil)
        STATIC_CLASS_SOURCE_PATTERN = /^[ \t]*(?:%[-:\w]+)?(?:#[\w-]+)?\.[\w-]|[({][^)}\n]*\bclass\s*=/m

        def self.parse_haml(source, module_id: nil)
          parser = ParserWithMetadata.new({})
          parser.call(source)
        rescue Haml::SyntaxError => error
          raise ParseError.new(error, source: source, module_id: module_id)
        end

        class ParserWithMetadata < Haml::Parser
          def initialize(...)
            @tag_metadata_by_line = Hash.new { |hash, key| hash[key] = [] }
            super
          end

          def call(source)
            root = super
            annotate_tag_nodes(root)
            root
          end

          private

          def parse_tag(text)
            result = super
            _, shorthand_attributes, attribute_hashes = result
            @tag_metadata_by_line[@line.index + 1] << class_metadata(shorthand_attributes, attribute_hashes)
            result
          end

          def annotate_tag_nodes(root)
            queue = root.children.dup
            until queue.empty?
              node = queue.shift
              if node.type == :tag
                metadata = @tag_metadata_by_line.fetch(node.line, []).shift
                node.value[:klenod_class_metadata] = metadata if metadata
              end
              queue.concat(node.children)
            end
          end

          def class_metadata(shorthand_attributes, attribute_hashes)
            shorthand = Haml::Parser.parse_class_and_id(shorthand_attributes).fetch("class", "").split
            literal = []

            if (new_attributes = attribute_hashes[:new])
              literal.concat(Array(new_attributes.fetch(0)["class"]).flat_map { it.to_s.split })
            end

            if (old_attributes = attribute_hashes[:old])
              literal.concat(literal_class_names_from_old_attributes(old_attributes))
            end

            {shorthand: shorthand, literal: literal}
          end

          def literal_class_names_from_old_attributes(source)
            parsed = Haml::AttributeParser.parse(source)
            return [] unless parsed&.key?("class")

            value = static_string_literal_value(parsed.fetch("class"))
            value ? value.split : []
          end

          def static_string_literal_value(source)
            case Ripper.sexp(source)
            in [:program, [[:string_literal, [:string_content, [:@tstring_content, String => value, _location]]]]]
              value
            else
              nil
            end
          end
        end

        class Transformer
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
              haml_helper_source: nil
            )
              component_program(
                component_class_name: component_class_name,
                component_base_class: component_base_class,
                translations_source: translations_source,
                ruby_source: ruby_source,
                render_source: render_source,
                styles_source: styles_source,
                haml_helper_source: haml_helper_source
              ).source
            end

            def component_program(
              component_class_name:,
              component_base_class:,
              translations_source:,
              ruby_source:,
              render_source:,
              styles_source:,
              haml_helper_source: nil
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
                  ruby_source: ruby_source,
                  render_source: render_source
                )
              footer = [
                constant_assignment("Default", component_class_name),
                constant_assignment("ClassNames", styles_source),
                call(receiver: "Default", name: "const_set", arguments: [symbol("ClassNames"), "ClassNames"]),
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
              body_fragments =
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
              explain =
                SyntaxSuggest::ExplainSyntax.new(
                  code_lines: SyntaxSuggest::CodeLine.from_source(source)
                ).call
              errors = explain.errors
              missing = explain.missing.map { |item| explain.why(item) } - errors

              message = ["#{context}: #{source.inspect}"]
              message << "Errors:\n  #{errors.join("\n  ")}" unless errors.empty?
              message << "Missing:\n  #{missing.join("\n  ")}" unless missing.empty?

              raise RubyParseError.new(message.join("\n\n"), line: line_no)
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
            styleable: false,
            profiler: nil,
            import_rewriter: nil,
            markdown_components_source: "{}",
            global_variables: nil,
            haml_helper_source: nil
          )
            component_base_class = ConstPath.parse(component_base_class, name: "component_base_class")
            factory = ConstPath.parse(factory, name: "factory")
            builder = RubyBuilder.new(profiler: profiler, global_variables: global_variables)
            haml_helper_source ||= builder.constant_assignment("HamlHelper", "Object") if styleable
            previous_profiler = @profiler
            previous_module_id = @module_id
            @profiler = profiler
            @module_id = module_id
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
                    haml_helper_source: haml_helper_source
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
                  haml_helper_source: haml_helper_source
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
          end

          private

          Template = Data.define(:ruby, :render)

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

            Template.new(ruby, render)
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

          def compile_node(node, factory:, builder:, markdown_compiler:, styleable: false)
            measure_compile_detail(:"haml_compile_node_#{node.type}") do
              mark = source_mark(node, builder: builder)
              expression =
                case node.type
                when :tag
                  builder.marked_expression(mark, compile_tag(node, mark: mark, factory: factory, styleable: styleable, builder: builder, markdown_compiler: markdown_compiler))
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
            source = +""
            text.each_line.with_index(node.line + 1) do |line, line_no|
              source << "\n" unless source.empty?
              source << builder.source_mark(line_no, nil)
              source << "\n"
              source << builder.line_rewritten_source(line.chomp, line_no).chomp
            end

            builder.node_fragment(source, nil)
          end

          def compile_filter_node(node, builder:, markdown_compiler:)
            return builder.render_ruby_filter(compile_ruby_filter(node, builder: builder)) if ruby_filter?(node)
            return builder.expression(markdown_compiler.compile(node.value.fetch(:text))) if markdown_filter?(node)

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

              hash = builder.hash_expression(source)
              return {} unless hash

              dynamic = {}
              hash.node.assocs.each do |assoc|
                key = attribute_key(assoc.key, builder: builder)
                value = builder.node_fragment(node_source(source, assoc.value), assoc.value)
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

              [match[1].to_sym, builder.node_fragment(value, nil)]
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

          def attribute_key(node, builder:)
            case node
            when SyntaxTree::Label
              node.value.delete_suffix(":").to_sym
            when SyntaxTree::StringLiteral
              node.parts.map(&:value).join.to_sym
            else
              builder.fragment(node).source.to_sym
            end
          end

          def source_mark(node, builder:)
            builder.source_mark(node.line, nil)
          end
        end

        def initialize(
          component_base_class: DEFAULT_COMPONENT_BASE_CLASS,
          factory: DEFAULT_FACTORY,
          global_variables: nil
        )
          @component_base_class = component_base_class
          @factory = factory
          @global_variables = validate_global_variables(global_variables)
          @transformer = Transformer.new
        end

        def resolve(dependency, _context)
          styles_dependency = resolve_class_names_runtime(dependency)
          return styles_dependency if styles_dependency

          return nil unless dependency.specifier == HAML_HELPER_SPECIFIER

          ResolvedDependency.new(dependency, HAML_HELPER_MODULE_ID, {virtual: true})
        end

        def load(module_id, _context)
          styles_load = load_class_names_runtime(module_id)
          return styles_load if styles_load

          return nil unless module_id.scheme == :virtual && module_id == HAML_HELPER_MODULE_ID

          LoadResult.new(haml_helper_source, nil, TransformResult.new(haml_helper_source, [], nil, [], [], {}))
        end

        def transform(module_id, code, context)
          return super unless module_id.extname == ".haml"

          companion_css = companion_path(module_id, ".css")
          dependencies = []
          style_dependencies = []
          import_dependencies = []
          watched_patterns = []
          markdown_filters = markdown_filter_nodes(code, module_id: module_id)
          profiler = context.respond_to?(:profiler) ? context.profiler : nil
          builder = Transformer::RubyBuilder.new(profiler: profiler)
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
          markdown_components_dependency = nil
          if markdown_filters.any?
            markdown_components_id = ModuleId.new("markdown-components.rb", nil)
            watched_patterns << WatchedPattern.new(module_id, markdown_components_id.path, :markdown_components, {})
            if context.absolute_path(markdown_components_id).file?
              markdown_components_dependency =
                Dependency
                  .create(
                    specifier: "/markdown-components",
                    importer_id: module_id,
                    kind: :markdown_components,
                    metadata: {optional: true}
                  )
                  .with(id: "#{module_id}:markdown_components")
              dependencies << markdown_components_dependency
            end
          end
          inline_css_sources(code, module_id: module_id).each_with_index do |source, index|
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
          class_names_runtime_dependency = class_names_runtime_dependency(module_id)
          dependencies << class_names_runtime_dependency
          styles_source = styles_source_for(builder, style_dependencies, class_names_runtime_dependency: class_names_runtime_dependency)
          haml_helper_needed = haml_helper_needed?(code, styleable: !style_dependencies.empty?)
          haml_helper_dependency = haml_helper_dependency(module_id) if haml_helper_needed
          dependencies << haml_helper_dependency if haml_helper_dependency
          translations_source = builder.frozen_literal(translations_for(context, module_id)).source
          component_class_name = component_class_name(module_id)
          import_rewriter =
            lambda do |source|
              result =
                RubyImportRewriter
                  .new(
                    module_id: module_id,
                    kind: :haml_import,
                    source_dir: context.source_dir,
                    profiler: profiler,
                    dependency_id_offset: import_dependencies.length
                  )
                  .rewrite(source)
              import_dependencies.concat(result.dependencies)
              watched_patterns.concat(result.watched_patterns)
              result.code
            end
          haml_result =
            @transformer.call(
              source: code,
              module_id: module_id,
              component_class_name: component_class_name,
              component_base_class: @component_base_class,
              factory: @factory,
              styles_source: styles_source,
              translations_source: translations_source,
              haml_helper_source: haml_helper_dependency && builder.constant_assignment("HamlHelper", "#{builder.import_call(haml_helper_dependency.id).source}::Default"),
              styleable: !style_dependencies.empty?,
              profiler: profiler,
              import_rewriter: import_rewriter,
              markdown_components_source: markdown_components_dependency ? "__klenod_import__(#{markdown_components_dependency.id.inspect})::Default" : "{}",
              global_variables: @global_variables
            )
          import_rewrite =
            if !haml_result.code.include?("import(") && !haml_result.code.include?("lazy_import(") && !haml_result.code.include?("import_glob(")
              RubyImportRewriter::Result.new(haml_result.code, [], [])
            elsif profiler
              profiler.measure(:haml_import_rewrite, module_id: module_id.to_s) do
                RubyImportRewriter
                  .new(
                    module_id: module_id,
                    kind: :haml_import,
                    source_dir: context.source_dir,
                    profiler: profiler,
                    dependency_id_offset: import_dependencies.length
                  )
                  .rewrite(haml_result.code)
              end
            else
              RubyImportRewriter
                .new(
                  module_id: module_id,
                  kind: :haml_import,
                  source_dir: context.source_dir,
                  dependency_id_offset: import_dependencies.length
                )
                .rewrite(haml_result.code)
            end

          watched_patterns.concat(import_rewrite.watched_patterns)

          TransformResult.new(
            import_rewrite.code,
            dependencies + import_dependencies + import_rewrite.dependencies,
            haml_result.source_map,
            [],
            companion_patterns(module_id) + watched_patterns,
            haml_result.metadata
          )
        end

        def import_value(resolved_dependency, record, context)
          styles_import = class_names_runtime_import_value(resolved_dependency, record, context)
          return styles_import if styles_import
          return nil unless record.id.extname == ".haml"

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        def runtime_import_value(resolved_dependency, record, _context)
          styles_import = class_names_runtime_runtime_import_value(resolved_dependency, record)
          return styles_import if styles_import
          return Runtime::DefaultImport.new(:Default) if record.id.extname == ".haml"

          super
        end

        def invalidate_module_ids(paths, context)
          paths
            .filter_map { |path| companion_owner_module_id(path, context) }
            .uniq
        end

        private

        def validate_global_variables(global_variables)
          return nil if global_variables.nil?

          source = global_variables.to_s
          parsed = SyntaxTree.parse(source)&.statements&.body
          raise ArgumentError, "global_variables must be a Ruby expression" unless parsed&.length == 1

          source
        rescue SyntaxTree::Parser::ParseError
          raise ArgumentError, "global_variables must be a Ruby expression"
        end

        def translations_for(context, module_id)
          intl_plugin = context.plugins.find { |plugin| plugin.respond_to?(:translations_for) }
          intl_plugin ? intl_plugin.translations_for(context, module_id) : {}
        end

        def haml_helper_dependency(module_id)
          Dependency
            .create(
              specifier: HAML_HELPER_SPECIFIER,
              importer_id: module_id,
              kind: :haml_helper
            )
            .with(id: "#{module_id}:haml_helper")
        end

        def haml_helper_source
          <<~RUBY
            # frozen_string_literal: true

            module Default
              def self.merge_props(component_class, *sources)
                result = {}
                classes = []

                sources.each do |source|
                  next unless source

                  source.each do |key, value|
                    key = normalize_prop_key(key)
                    if key == :class
                      collect_class_values(classes, value)
                    else
                      result[key] = value
                    end
                  end
                end

                class_name = class_name(component_class, classes)
                result[:class] = class_name if class_name
                result
              end

              def self.normalize_prop_key(key)
                return key if key.is_a?(Symbol) && !key.to_s.include?("-")

                key.to_s.tr("-", "_").to_sym
              end

              def self.collect_class_values(classes, value)
                case value
                when nil, false
                  nil
                when Array
                  value.each { |item| collect_class_values(classes, item) }
                else
                  classes << value
                end
              end

              def self.class_name(component_class, classes)
                return nil if classes.empty?

                styles = component_class.const_defined?(:ClassNames, false) ? component_class::ClassNames : nil
                return nil unless styles.respond_to?(:class_name)

                styles.class_name(*classes)
              end
            end
          RUBY
        end

        def haml_helper_needed?(source, styleable:)
          return true if styleable

          source.match?(STATIC_CLASS_SOURCE_PATTERN)
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

        def inline_css_sources(source, module_id: nil)
          filter_nodes(source, "css", module_id: module_id).map { |node| node.value.fetch(:text) }
        end

        def markdown_filter_nodes(source, module_id: nil)
          return [] unless source.include?(":markdown")

          filter_nodes(source, "markdown", module_id: module_id)
        end

        def filter_nodes(source, name, module_id: nil)
          nodes = []
          queue = HamlPlugin.parse_haml(source, module_id: module_id).children.dup

          until queue.empty?
            node = queue.shift
            nodes << node if node.type == :filter && node.value.fetch(:name) == name
            queue.concat(node.children)
          end

          nodes
        end

        def styles_source_for(builder, dependencies, class_names_runtime_dependency:)
          class_names_runtime = builder.import_call(class_names_runtime_dependency.id).source
          imports = dependencies.map { |dependency| builder.import_call(dependency.id) }
          return "#{class_names_runtime}.new({}.freeze)" if imports.empty?
          return imports.fetch(0).source if imports.length == 1

          builder
            .expression(
              "#{class_names_runtime}.merge(#{imports.map(&:source).join(", ")})"
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

        def companion_owner_module_id(path, context)
          relative_path = Pathname.new(path).expand_path.relative_path_from(context.source_dir).to_s
          owner_path =
            if relative_path.end_with?(".css")
              relative_path.delete_suffix(".css") + ".haml"
            elsif relative_path.match?(/\.intl\.[^\/]+\.toml\z/)
              relative_path.sub(/\.intl\.[^\/]+\.toml\z/, ".haml")
            end
          return nil unless owner_path

          owner_id = ModuleId.new(owner_path, nil)
          owner_id if context.absolute_path(owner_id).file?
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
