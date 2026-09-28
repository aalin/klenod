# frozen_string_literal: true

require "prism"
require "ripper"
require "syntax_suggest/api"
require "syntax_suggest/explain_syntax"

module Klenod
  module Build
    module Plugins
      module HamlPlugin
        class Transformer
          class RubyBuilder
            # `node` is the Prism node parsed from user Ruby, for the places
            # that inspect it. `statements` marks a statement list, which is
            # wrapped in `begin`/`end` when it is used as an argument.
            Fragment = Data.define(:source, :node, :statements) do
              def initialize(source:, node: nil, statements: false)
                super
              end

              def node?
                !node.nil?
              end

              def to_s
                source
              end
            end

            def initialize(profiler: nil, variables: nil)
              @profiler = profiler
              @variables = variables || {}
              @expression_cache = {}
              @statements_cache = {}
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
                Fragment.new("# frozen_string_literal: true"),
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

              Fragment.new(
                [
                  "class #{to_source(component_class_name)} < #{to_source(component_base_class)}",
                  indent(compact_join(body_fragments), 2),
                  "end"
                ].join("\n")
              )
            end

            def expressions(expressions)
              source_expressions(expressions)
            end

            def expression(source, line_no: nil)
              source = rewrite_ruby_source(source, line_no)

              Fragment.new(source, parse_expression(source, context: :expression))
            end

            def statements(source, line_no: nil)
              source = rewrite_ruby_source(source, line_no)
              node = parse_statements(source)

              Fragment.new(source, node, !node.nil?)
            end

            def program_from_fragments(*fragments)
              Fragment.new(compact_join(fragments.flatten))
            end

            # Reprints parsed user Ruby exactly as it was written.
            def fragment(node)
              Fragment.new(node.slice, node)
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
              Fragment.new(literal_source(value))
            end

            def frozen_literal(value)
              Fragment.new(frozen_literal_source(value))
            end

            def import_call(dependency_id)
              Fragment.new("__klenod_import__(#{literal_source(dependency_id)})")
            end

            def constant_assignment(name, value)
              value = expression_fragment(value)
              Fragment.new("#{name} = #{to_source(value)}")
            end

            def call(receiver:, name:, arguments:)
              receiver = expression_fragment(receiver) unless receiver.nil?
              arguments = arguments.map { |argument| expression_fragment(argument) }
              receiver_prefix = receiver ? "#{to_source(receiver)}." : nil
              Fragment.new("#{receiver_prefix}#{name}(#{arguments.map { |argument| to_source(argument) }.join(", ")})")
            end

            def method_definition(name, body:, target: nil, parameters: [])
              body_source = compact_join(Array(body))
              target_source = target ? "#{to_source(expression_fragment(target))}." : ""
              params_source = parameters.empty? ? "" : "(#{parameters.join(", ")})"
              Fragment.new(["def #{target_source}#{name}#{params_source}", indent(body_source, 2), "end"].join("\n"))
            end

            def public_method_definition(name, body:, parameters: [])
              method = method_definition(name, parameters: parameters, body: body)
              Fragment.new("public #{method.source}")
            end

            def nil_expression
              Fragment.new("nil")
            end

            def file_expression
              Fragment.new("__FILE__")
            end

            def symbol(value)
              Fragment.new(symbol_source(value.to_s))
            end

            def symbol_fragment(value)
              Fragment.new(symbol_source(value.to_s))
            end

            def styles_lookup(name)
              Fragment.new("ClassNames[#{symbol_source(name.to_s)}]")
            end

            def class_name_lookup(name)
              Fragment.new("ClassNames[#{symbol_source(name.to_s)}]")
            end

            def class_names(values)
              fragments = values.map { |value| expression_fragment(value) }

              Fragment.new("ClassNames.class_name(#{fragments.map(&:source).join(", ")})")
            end

            def scoped_class_name(values)
              fragments = values.map { |value| expression_fragment(value) }

              Fragment.new("ClassNames.class_name(#{fragments.map(&:source).join(", ")})")
            end

            def parenthesized_expression(source, line_no: nil)
              source = rewrite_ruby_source(source, line_no)
              result = parse_result(source)
              unless result
                raise_ruby_parse_error(source, line_no: line_no, context: "Could not parse Haml output script", syntax_error: true)
              end

              # A trailing comment would otherwise swallow the closing parenthesis.
              closing = result.comments.empty? ? ")" : "\n)"
              Fragment.new("(#{source}#{closing}", result.value.statements.body.first)
            end

            def hash_expression(source, line_no: nil)
              source = rewrite_ruby_source(source, line_no)
              node = parse_expression(source, context: :hash_expression)
              return nil unless node.is_a?(Prism::HashNode)

              Fragment.new(source, node)
            end

            def source_mark(line_no, _source)
              "# #{Runtime::SourceMap::MARK_PREFIX}:#{line_no}"
            end

            def marked_expression(mark, expression)
              Fragment.new("#{mark}\n#{to_source(expression)}", nil, true)
            end

            def factory_call(factory:, tag:, children:, props:, mark: nil)
              source_factory_call(factory: factory, tag: tag, children: children, props: props, mark: mark)
            end

            def component_factory_call(factory:, tag:, children:, props:, mark: nil)
              call = source_factory_call(factory: factory, tag: tag, children: [], props: props, mark: mark)
              body = Fragment.new("[#{children.map { |child| argument_source(child) }.join(", ")}]")
              script_block("#{call.source} do", body)
            end

            def slot_call(name:, fallback:)
              arguments = ["self", name ? argument_source(name) : "nil"]
              arguments << argument_source(fallback) if fallback
              expression("HamlHelper.render_slot(#{arguments.join(", ")})")
            end

            def freeze_static(value)
              expression("HamlHelper.freeze_static(#{argument_source(value)})")
            end

            def class_values(values)
              source_expressions(values)
            end

            def script_block(source, body, line_no: nil)
              source = rewrite_ruby_source(source, nil)
              return Fragment.new(block_source(source, body)) if block_script?(source)

              raise_ruby_parse_error(source, line_no: line_no, context: "Could not build Ruby block from Haml script")
            end

            def silent_script_block(source, body, line_no: nil)
              source = rewrite_ruby_source(source, nil)
              ast_silent_script_block(source, body) || raise_ruby_parse_error(source, line_no: line_no, context: "Could not build Ruby block from Haml script", syntax_error: true)
            end

            def silent_script(source, line_no: nil)
              source = rewrite_ruby_source(source, nil)
              fragment = ast_silent_script(source)
              return fragment if fragment

              raise_ruby_parse_error(source, line_no: line_no, context: "Could not parse Haml silent script", syntax_error: true)
            end

            def silent_script_with_children(source, body, line_no: nil)
              source = rewrite_ruby_source(source, nil)
              return_with_children = false

              # A modifier return with an indented Haml block returns that block
              # when the condition matches. Keeping the return and its children
              # as sequential statements would instead evaluate the children
              # after the modifier has fallen through.
              if source == "return"
                source = "return #{argument_source(body)}"
                return_with_children = true
              elsif (match = source.match(/\Areturn\s+(if|unless)\s+(.+)\z/))
                branch, condition = match.captures
                source = "#{branch} #{condition}\n#{indent("return #{argument_source(body)}", 2)}\nend"
                return_with_children = true
              end

              statements = parse_statements(source)
              unless statements
                raise_ruby_parse_error(source, line_no: line_no, context: "Could not parse Haml silent script", syntax_error: true)
              end

              return Fragment.new(source, statements, true) if return_with_children

              Fragment.new(["begin", indent(source, 2), indent(to_source(body), 2), "end"].join("\n"))
            end

            def keyword_script?(source)
              source.start_with?("while ", "until ", "for ")
            end

            def keyword_script(source, body, line_no: nil)
              source = rewrite_ruby_source(source, nil)
              source = block_source(source, body)
              node = parse_expression(source, context: :keyword_script)
              return Fragment.new(source, node) if node

              raise_ruby_parse_error(source, line_no: line_no, context: "Could not build Ruby control-flow block from Haml script", syntax_error: true)
            end

            def silent_keyword_script(source, body, line_no: nil)
              captured_script = captured_block_source(source, body)
              node = parse_expression(captured_script, context: :keyword_script)
              return Fragment.new(captured_script, node) if node

              raise_ruby_parse_error(captured_script, line_no: line_no, context: "Could not build Ruby control-flow block from Haml script", syntax_error: true)
            end

            def branches(branches, line_no: nil)
              fragment = ast_branches(branches)
              return fragment if fragment

              raise_ruby_parse_error(branch_source(branches), line_no: line_no, context: "Could not parse Haml output branches", syntax_error: true)
            end

            def silent_branches(branches, line_no: nil)
              fragment = ast_branches(branches)
              return fragment if fragment

              raise_ruby_parse_error(branch_source(branches), line_no: line_no, context: "Could not parse Haml silent branches", syntax_error: true)
            end

            def ruby_filters(nodes)
              return "" if nodes.empty?

              Fragment.new(nodes.map { |node| ["begin", indent(to_source(node), 2), "end"].join("\n") }.join("\n"), nil, true)
            end

            def render_ruby_filter(node)
              source = to_source(node)
              parsed = node.is_a?(Fragment) && node.node?
              unless parsed || parse_statements(source)
                raise_ruby_parse_error(source, line_no: nil, context: "Could not parse Ruby filter")
              end

              Fragment.new(["begin", indent(source.rstrip, 2), "  nil", "end"].join("\n"))
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

            # Whether the script opens a literal block for its Haml children.
            # Calls, `super`, and zsuper can take one; lambdas cannot.
            def block_script?(source)
              node = parse_expression(fix_syntax_by_adding_missing_pairs(source), context: :block_script)

              node.respond_to?(:block) && node.block.is_a?(Prism::BlockNode)
            end

            private

            def rewrite_ruby_source(source, line_no)
              source = rewrite_line_constant(source, line_no)
              rewrite_variables(source)
            end

            def rewrite_line_constant(source, line_no)
              return source.to_s unless line_no

              source = source.to_s
              return source unless source.include?("__LINE__")

              line_offsets = [0]
              source.each_line(chomp: false) { |line| line_offsets << line_offsets.last + line.bytesize }

              Ripper
                .lex(source)
                .select { |(_line, _column), type, token, _state| type == :on_kw && token == "__LINE__" }
                .reverse_each
                .each_with_object(source.dup) do |((line, column), _type, token, _state), rewritten|
                  offset = line_offsets.fetch(line - 1) + column
                  rewritten.bytesplice(offset, token.bytesize, line_no.to_s)
                end
            end

            VARIABLE_TOKEN_KINDS = {
              on_gvar: [:global, "$", /\A\$[a-z]\w*\z/],
              on_cvar: [:class, "@@", /\A@@[a-z]\w*\z/],
              on_ivar: [:instance, "@", /\A@[a-z]\w*\z/]
            }.freeze

            def rewrite_variables(source)
              return source if @variables.empty?

              line_offsets = [0]
              source.each_line(chomp: false) { |line| line_offsets << line_offsets.last + line.bytesize }

              tokens = Ripper.lex(source)

              tokens
                .each_with_index
                .filter_map do |((line, column), type, token, _state), index|
                  kind, prefix, pattern = VARIABLE_TOKEN_KINDS[type]
                  receiver = @variables[kind]
                  if type == :on_gvar && token == "$*" && receiver
                    [offset_for(line_offsets, line, column), token.bytesize, receiver]
                  elsif receiver && token.match?(pattern)
                    name = token.delete_prefix(prefix)
                    replacement = "(#{receiver})[#{symbol_source(name)}]"
                    replacement = "{#{replacement}}" if tokens[index - 1]&.fetch(1) == :on_embvar
                    [offset_for(line_offsets, line, column), token.bytesize, replacement]
                  end
                end
                .reverse_each
                .each_with_object(source.dup) do |(offset, length, replacement), rewritten|
                  rewritten.bytesplice(offset, length, replacement)
                end
            end

            def offset_for(line_offsets, line, column)
              line_offsets.fetch(line - 1) + column
            end

            def source_expressions(expressions)
              case expressions.length
              when 0
                nil_expression
              when 1
                expression = expressions.fetch(0)

                expression.is_a?(Fragment) ? expression : self.expression(to_source(expression))
              else
                Fragment.new("[#{expressions.map { |item| argument_source(item) }.join(", ")}]")
              end
            end

            def source_factory_call(factory:, tag:, children:, props:, mark:)
              factory = expression_fragment(factory)
              tag = expression_fragment(tag)
              children = children.map { |child| expression_fragment(child) }
              props = props.dup
              attribute_splats = props.delete(:__klenod_attribute_splats__) || []
              prop_sources = ["{#{keyword_props_source(props, mark: mark).join(", ")}}", *attribute_splats.map { |value| argument_source(value) }]

              source_parts = [
                to_source(tag),
                *children.map { |child| argument_source(child) },
                "**HamlHelper.merge_props(self.class, #{prop_sources.join(", ")})"
              ].compact
              Fragment.new("#{to_source(factory)}[#{source_parts.join(", ")}]")
            end

            def ast_silent_script(source)
              return nil unless parse_statements(source)

              Fragment.new(["begin", indent(source, 2), "  nil", "end"].join("\n"))
            end

            def ast_silent_script_block(source, body)
              source = captured_block_source(source, body)
              node = parse_expression(source, context: :block_script)
              return nil unless node

              Fragment.new(source, node)
            end

            def ast_branches(branches)
              source = branch_source(branches)
              node = parse_expression(source, context: :branches)
              return nil unless node

              Fragment.new(source, node)
            end

            def block_source(source, body)
              body_source = to_source(body)

              if source.include?("{") && !source.end_with?(" do")
                "#{source} #{body_source} }"
              else
                [source, indent(body_source, 2), "end"].join("\n")
              end
            end

            # Ruby iterators and keyword loops return their control value rather
            # than the values produced by their bodies. Capture each compiled
            # Haml child explicitly, while leaving `return`, `next`, and `break`
            # in their original Ruby block/loop context.
            def captured_block_source(source, body)
              captured_body = "HamlHelper.append_capture(#{argument_source(body)})"
              script = block_source(source, Fragment.new(captured_body))
              ["HamlHelper.capture do", indent(script, 2), "end"].join("\n")
            end

            def branch_source(branches)
              body =
                branches
                  .each_with_index
                  .map do |(source, body), index|
                    if index.zero? && source.match?(/\Acase\b/)
                      source
                    elsif source == "else"
                      ["else", indent(to_source(body), 2)].join("\n")
                    else
                      [source, indent(to_source(body), 2)].join("\n")
                    end
                  end
                  .join("\n")

              "#{body}\nend"
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

            def frozen_literal_source(value)
              case value
              when Hash
                "{#{value.map { |key, child| "#{literal_source(key)} => #{frozen_literal_source(child)}" }.join(", ")}}.freeze"
              when Array
                "[#{value.map { |child| frozen_literal_source(child) }.join(", ")}].freeze"
              else
                literal_source(value)
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

            def symbol_source(value)
              if value.match?(/\A[a-zA-Z_]\w*[!?=]?\z/)
                ":#{value}"
              else
                ":#{value.inspect}"
              end
            end

            def argument_source(value, mark: nil)
              fragment = expression_fragment(value)
              source = to_source(fragment)

              if mark
                source = "#{mark}\n#{source}"
              end

              if fragment.statements || mark || (source.include?("\n") && !multiline_argument_expression?(source))
                ["begin", indent(source, 2), "end"].join("\n")
              else
                source
              end
            end

            def multiline_argument_expression?(source)
              source.start_with?("if ", "unless ", "case", "begin")
            end

            def parse_expression(source, context:)
              cached_parse(@expression_cache, source, :"haml_parse_expression:#{context}") do
                parse_result(source)&.value&.statements&.body&.first
              end
            end

            def parse_statements(source)
              cached_parse(@statements_cache, source, :haml_parse_statements) { parse_result(source)&.value&.statements }
            end

            # Haml scripts are fragments of a larger render method, so accept
            # `yield`, `next`, and `break` outside of a block or loop.
            def parse_result(source)
              result = Prism.parse(source.to_s, partial_script: true)
              result if result.success?
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

            def raise_ruby_parse_error(source, line_no:, context:, syntax_error: false)
              error_line = parse_error_line(source)
              explain =
                SyntaxSuggest::ExplainSyntax.new(
                  code_lines: SyntaxSuggest::CodeLine.from_source(source)
                ).call
              errors = explain.errors
              missing = explain.missing.map { |item| explain.why(item) } - errors

              message = [context]
              message[0] += " (Ruby syntax error)" if syntax_error
              message << "Errors:\n  #{errors.join("\n  ")}" unless errors.empty?
              message << "Missing:\n  #{missing.join("\n  ")}" unless missing.empty?

              raise RubyParseError.new(message.join("\n\n"), line: source_line_for_parse_error(line_no, error_line))
            end

            # Prism first reports an unclosed `{` or `(` at the line that opens
            # it. The unexpected token that broke it is the line to show.
            def parse_error_line(source)
              errors = Prism.parse(source.to_s, partial_script: true).errors
              error = errors.reject { it.type.end_with?("_term") }.min_by { it.location.start_offset } || errors.first
              error&.location&.start_line
            end

            def source_line_for_parse_error(line_no, error_line)
              return line_no unless line_no && error_line

              line_no + error_line - 1
            end
          end
        end
      end
    end
  end
end
