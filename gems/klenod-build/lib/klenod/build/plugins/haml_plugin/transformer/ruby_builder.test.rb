# frozen_string_literal: true

require_relative "../test_support"

class Klenod::Build::Plugins::HamlPlugin::RubyBuilderTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_ruby_builder_wraps_configured_variables_in_braces_when_interpolated
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new(
      variables: {global: "@__props", class: "context", instance: "@__state"}
    )

    source = builder.line_rewritten_source("\"\#$title \#@@request \#@count\"", nil)

    assert_equal("\"\#{(@__props)[:title]} \#{(context)[:request]} \#{(@__state)[:count]}\"", source)
  end

  def test_ruby_builder_only_rewrites_interpolated_variable_kinds_that_are_configured
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new(variables: {global: "@__props"})

    source = builder.line_rewritten_source("\"\#$title \#@@request \#@count\"", nil)

    assert_equal("\"\#{(@__props)[:title]} \#@@request \#@count\"", source)
  end

  def test_ruby_builder_rewrites_variables_after_multibyte_characters
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new(variables: {instance: "@__state"})

    source = builder.line_rewritten_source("(@text.empty? ? \"–\" : @text)", nil)

    assert_equal("((@__state)[:text].empty? ? \"–\" : (@__state)[:text])", source)
  end

  def test_ruby_builder_rewrites_variables_after_multibyte_characters_on_earlier_lines
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new(variables: {instance: "@__state"})

    source = builder.line_rewritten_source("dash = \"–\"\n@text || dash", nil)

    assert_equal("dash = \"–\"\n(@__state)[:text] || dash", source)
  end

  def test_ruby_builder_rewrites_line_constant_after_multibyte_characters
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    source = builder.line_rewritten_source("[\"–\", __LINE__]", 7)

    assert_equal("[\"–\", 7]", source)
  end

  def test_ruby_builder_raises_for_an_unparseable_render_ruby_filter
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    error = assert_raises(Klenod::Build::Plugins::HamlPlugin::RubyParseError) do
      builder.render_ruby_filter("things = {\n  foo: \"Foo\"\n  bar: \"Bar\"\n}\n")
    end

    assert_includes(error.message, "Could not parse Ruby filter")
  end

  def test_ruby_builder_builds_unmarked_factory_calls
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.factory_call(
        factory: "#{self.class.name}::FakeFramework::H",
        tag: ":p",
        children: ["\"Hello\""],
        props: {class: "\"intro\""}
      )

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, fragment)
    assert_nil(fragment.node)
    assert_includes(fragment.source, "#{self.class.name}::FakeFramework::H[")
    assert_includes(fragment.source, ":p")
    assert_includes(fragment.source, '"Hello"')
    assert_includes(fragment.source, 'class: "intro"')
    assert_valid_ruby(fragment.source)
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_factory_calls
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    child = builder.marked_expression(builder.source_mark(2, "Hello"), builder.expression("\"Hello\""))
    fragment =
      builder.factory_call(
        factory: "#{self.class.name}::FakeFramework::H",
        tag: ":p",
        children: [child],
        props: {class: "\"intro\""},
        mark: builder.source_mark(1, "p")
      )

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, fragment)
    assert_nil(fragment.node)
    assert_includes(fragment.source, "# SourceMapMark:1")
    assert_includes(fragment.source, "# SourceMapMark:2")
    assert_includes(fragment.source, "class:")
    assert_includes(fragment.source, '"intro"')
    assert_valid_ruby(fragment.source)
  end

  def test_ruby_builder_builds_component_factory_calls_with_lazy_children
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.component_factory_call(
        factory: "#{self.class.name}::FakeFramework::H",
        tag: "Card",
        children: ['"Title"', 'H[:p, "Body"]'],
        props: {title: '"Hello"'}
      )

    assert_includes(fragment.source, "H[Card, **HamlHelper.merge_props(self.class, {title: \"Hello\"})] do")
    assert_includes(fragment.source, '["Title", H[:p, "Body"]]')
  end

  def test_ruby_builder_fragments_keep_parsed_prism_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    unmarked = builder.expression('H[:p, **{:class => "intro"}]')

    assert_kind_of(Prism::CallNode, unmarked.node)
    assert_equal('H[:p, **{:class => "intro"}]', unmarked.source)
  end

  def test_ruby_builder_reprints_parsed_nodes_as_written
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    node = builder.expression('H[:p,  **{:class=>"intro"}]').node
    fragment = builder.fragment(node)

    assert_same(node, fragment.node)
    assert(fragment.node?)
    assert_equal('H[:p,  **{:class=>"intro"}]', fragment.source)
  end

  def test_ruby_builder_composes_programs_from_statement_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    program =
      builder.program_from_fragments(
        builder.statements("# frozen_string_literal: true\n\nKlenodImport = nil\n"),
        builder.statements("class Page\nend\n"),
        builder.statements("Default = Page\n")
      )

    assert_equal(
      [Prism::ConstantWriteNode, Prism::ClassNode, Prism::ConstantWriteNode],
      Prism.parse(program.source).value.statements.body.map(&:class)
    )
    assert_includes(program.source, "# frozen_string_literal: true")
    assert_includes(program.source, "class Page")
    assert_includes(program.source, "Default = Page")
  end

  def test_ruby_builder_builds_literals_and_symbols
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    assert_equal('"Hello"', builder.literal("Hello").source)
    assert_equal('"\\#{title}"', builder.literal("\#{title}").source)
    assert_equal("123", builder.literal(123).source)
    assert_equal("true", builder.literal(true).source)
    assert_equal(":p", builder.symbol("p").source)
    assert_equal(':"article-card"', builder.symbol("article-card").source)
  end

  def test_ruby_builder_reuses_short_string_literals
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    assert_same(builder.literal(" "), builder.literal(" "))
    refute_same(builder.literal("Hello"), builder.literal("Hello"))
  end

  def test_ruby_builder_builds_frozen_literals
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    value = {
      "en-US" => {
        "title" => "Hello \#{name}",
        "items" => [1, 2]
      }
    }
    literal = builder.frozen_literal(value)

    assert_equal('{"en-US" => {"title" => "Hello \\#{name}", "items" => [1, 2].freeze}.freeze}.freeze', literal.source)

    evaluated = eval(literal.source) # standard:disable Security/Eval
    assert_equal(value, evaluated)
    assert_predicate(evaluated, :frozen?)
    assert_predicate(evaluated.fetch("en-US").fetch("items"), :frozen?)
  end

  def test_ruby_builder_builds_import_calls
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.import_call("pages/page.haml:companion_style")

    assert_equal('__klenod_import__("pages/page.haml:companion_style")', fragment.source)
  end

  def test_ruby_builder_builds_style_lookup_helpers
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    tag_lookup = builder.styles_lookup("__p")
    class_lookup = builder.class_name_lookup("article-card")
    class_names = builder.class_names([tag_lookup, class_lookup, builder.expression("dynamic_class")])

    assert_equal("ClassNames[:__p]", tag_lookup.source)
    assert_equal('ClassNames[:"article-card"]', class_lookup.source)
    assert_equal('ClassNames.class_name(ClassNames[:__p], ClassNames[:"article-card"], dynamic_class)', class_names.source)
  end

  def test_ruby_builder_builds_constant_assignments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    assert_equal("Default = Page", builder.constant_assignment("Default", "Page").source)
  end

  def test_ruby_builder_builds_method_calls
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    bare_call = builder.call(receiver: nil, name: "method", arguments: [builder.symbol("__klenod_import__")])
    receiver_call = builder.call(receiver: "Default", name: "const_set", arguments: [builder.symbol("ClassNames"), "ClassNames"])

    assert_equal("method(:__klenod_import__)", bare_call.source)
    assert_equal("Default.const_set(:ClassNames, ClassNames)", receiver_call.source)
  end

  def test_ruby_builder_builds_method_definitions
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.method_definition("title", body: builder.literal("Hello"))

    assert_equal(<<~RUBY.chomp, fragment.source)
      def title
        "Hello"
      end
    RUBY
  end

  def test_ruby_builder_builds_public_method_definitions
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(3, "title"), builder.expression("title"))
    fragment = builder.public_method_definition("render", body: body)

    assert_equal(<<~RUBY.chomp, fragment.source)
      public def render
        # SourceMapMark:3
        title
      end
    RUBY
  end

  def test_ruby_builder_statement_fragments_keep_parsed_statements
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.statements("first\nsecond\n")

    assert_kind_of(Prism::StatementsNode, fragment.node)
    assert_equal(2, fragment.node.body.length)
    assert(fragment.statements)
  end

  def test_ruby_builder_statement_fragments_are_wrapped_as_arguments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.factory_call(factory: "H", tag: ":p", children: [builder.statements("title")], props: {})

    assert_equal("H[:p, begin\n  title\nend, **HamlHelper.merge_props(self.class, {})]", fragment.source)
  end

  def test_ruby_builder_normalizes_values_into_expression_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    existing = builder.expression("Page")

    assert_same(existing, builder.expression_fragment(existing))

    fragment = builder.expression_fragment("Object")

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(Prism::ConstantReadNode, fragment.node)
    assert_equal("Object", fragment.source)
  end

  def test_ruby_builder_normalizes_values_into_statement_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    existing = builder.statements("def title\n  \"Hello\"\nend\n")

    assert_same(existing, builder.statements_fragment(existing))

    fragment = builder.statements_fragment("first\nsecond\n")

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(Prism::StatementsNode, fragment.node)
    assert_equal(2, fragment.node.body.length)
  end

  def test_ruby_builder_builds_parenthesized_expressions
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.parenthesized_expression("title.upcase")

    assert_kind_of(Prism::CallNode, fragment.node)
    assert_equal("(title.upcase)", fragment.source)
  end

  def test_ruby_builder_closes_parenthesized_expressions_after_trailing_comments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.parenthesized_expression("title.upcase # shout")

    assert_equal("(title.upcase # shout\n)", fragment.source)
    assert_valid_ruby("H[:p, #{fragment.source}]")
  end

  def test_ruby_builder_builds_hash_expressions
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.hash_expression("{ title: title.upcase }")

    assert_kind_of(Prism::HashNode, fragment.node)
    assert_equal("{ title: title.upcase }", fragment.source)
    assert_nil(builder.hash_expression("title"))
  end

  def test_ruby_builder_detects_scripts_that_open_a_block
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    assert(builder.block_script?("items.each do |item|"))
    assert(builder.block_script?("items.each { |item|"))
    assert(builder.block_script?("render_list(items) do"))
    assert(builder.block_script?("super do"))
    assert(builder.block_script?("super(title) do"))
    refute(builder.block_script?("-> do"))
    refute(builder.block_script?("items.each(&block)"))
    refute(builder.block_script?("title"))
  end

  def test_ruby_builder_component_program_builds_the_component_source
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    program =
      builder.component_program(
        component_class_name: "Page",
        component_base_class: "Object",
        translations_source: "{}.freeze",
        ruby_source: "",
        render_source: builder.expression('"Hello"'),
        styles_source: "{}.freeze"
      )

    assert_includes(Prism.parse(program.source).value.statements.body.map(&:class), Prism::ClassNode)
    assert_includes(program.source, "class Page < Object")
    assert_includes(program.source, "public def render")
  end

  def test_ruby_builder_builds_component_class_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.component_class_fragment(
        component_class_name: builder.expression_fragment("Page"),
        component_base_class: builder.expression_fragment("Object"),
        translations_source: builder.expression_fragment("{}.freeze"),
        styles_source: builder.expression_fragment("{ foo: \"foo_hash\" }.freeze"),
        i18n_source: builder.constant_assignment("I18n", "Framework::I18n.new(self)"),
        ruby_source: builder.statements_fragment("def title\n  \"Hello\"\nend\n"),
        render_source: builder.expression_fragment("title")
      )

    assert_valid_ruby(fragment.source)
    assert_includes(fragment.source, "class Page < Object")
    assert_includes(fragment.source, "Translations = {}.freeze")
    assert_includes(fragment.source, "I18n = Framework::I18n.new(self)")
    assert_includes(fragment.source, "ClassNames = { foo: \"foo_hash\" }.freeze")
    assert_includes(fragment.source, "def title")
    assert_includes(fragment.source, "public def render")
  end

  def test_ruby_builder_component_source_returns_component_program_source
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    kwargs = {
      component_class_name: "Page",
      component_base_class: "Object",
      translations_source: "{}.freeze",
      ruby_source: "",
      render_source: builder.expression('"Hello"'),
      styles_source: "{}.freeze"
    }

    assert_equal(builder.component_program(**kwargs).source, builder.component_source(**kwargs))
  end

  def test_ruby_builder_marked_expressions_prefix_the_source_mark
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    child = builder.expression('"Hello"')
    marked = builder.marked_expression(builder.source_mark(1, "Hello"), child)

    assert_equal("# SourceMapMark:1\n\"Hello\"", marked.source)
    assert(marked.statements)
  end

  def test_ruby_builder_builds_empty_expression_lists_as_nil
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    assert_equal("nil", builder.expressions([]).source)
    assert_equal("nil", builder.nil_expression.source)
  end

  def test_ruby_builder_reuses_single_expression_list_fragment
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    child = builder.expression('"Hello"')

    assert_same(child, builder.expressions([child]))
  end

  def test_ruby_builder_builds_unmarked_expression_lists_from_source
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.expressions([
        builder.expression('H[:p, "Hello"]'),
        builder.expression('H[:span, "World"]')
      ])

    assert_nil(fragment.node)
    assert_equal('[H[:p, "Hello"], H[:span, "World"]]', fragment.source)
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_expression_lists
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    child = builder.marked_expression(builder.source_mark(1, "Hello"), builder.expression('"Hello"'))
    fragment = builder.expressions([child, builder.expression('"World"')])

    assert_nil(fragment.node)
    assert_includes(fragment.source, "# SourceMapMark:1")
    assert_includes(fragment.source, '"World"')
    assert_valid_ruby(fragment.source)
  end

  def test_ruby_builder_builds_silent_scripts
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.silent_script("@visible = true")

    assert_equal(<<~RUBY.chomp, fragment.source)
      begin
        @visible = true
        nil
      end
    RUBY
  end

  def test_ruby_builder_accepts_control_flow_in_silent_scripts
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    assert_includes(builder.silent_script("next if hidden").source, "next if hidden")
    assert_includes(builder.silent_script("break").source, "break")
    assert_includes(builder.silent_script("yield").source, "yield")
  end

  def test_ruby_builder_builds_ruby_filters
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.ruby_filters([
        "#{builder.source_mark(2, "def title")}\ndef title\n  \"Hello\"\nend"
      ])

    assert_equal(<<~RUBY.chomp, fragment.source)
      begin
        # SourceMapMark:2
        def title
          "Hello"
        end
      end
    RUBY
    assert(fragment.statements)
  end

  def test_ruby_builder_builds_render_ruby_filters
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.render_ruby_filter("# SourceMapMark:4\ncurrent = request.path\n\n")

    assert_equal(<<~RUBY.chomp, fragment.source)
      begin
        # SourceMapMark:4
        current = request.path
        nil
      end
    RUBY
  end

  def test_ruby_builder_builds_script_blocks
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.script_block("items.map do |item|", body)

    assert_equal("items.map do |item|\n  H[:li, item]\nend", fragment.source)
  end

  def test_ruby_builder_builds_brace_script_blocks
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.script_block("items.map { |item|", body)

    assert_equal("items.map { |item| H[:li, item] }", fragment.source)
  end

  def test_ruby_builder_captures_silent_script_block_children
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.silent_script_block("items.each do |item|", body)

    assert_kind_of(Prism::CallNode, fragment.node)
    assert_equal(<<~RUBY.chomp, fragment.source)
      HamlHelper.capture do
        items.each do |item|
          HamlHelper.append_capture(H[:li, item])
        end
      end
    RUBY
  end

  def test_ruby_builder_captures_silent_brace_script_block_children
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.silent_script_block("items.each { |item|", body)

    assert_kind_of(Prism::CallNode, fragment.node)
    assert_equal(<<~RUBY.chomp, fragment.source)
      HamlHelper.capture do
        items.each { |item| HamlHelper.append_capture(H[:li, item]) }
      end
    RUBY
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_script_blocks
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(2, "item"), builder.expression("item"))
    fragment = builder.script_block("items.map do |item|", body)

    assert_includes(fragment.source, "# SourceMapMark:2")
    assert_includes(fragment.source, "items.map do |item|")
    assert_valid_ruby(fragment.source)
  end

  def test_ruby_builder_reports_helpful_script_block_parse_errors
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::RubyParseError) do
        builder.script_block("items.map { |item| )", body, line_no: 12)
      end

    assert_equal(12, error.line)
    assert_includes(error.message, "Could not build Ruby block from Haml script")
    assert_match(/Errors:|Missing:/, error.message)
  end

  def test_ruby_builder_reports_parse_errors_for_output_scripts
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    error = assert_raises(Klenod::Build::Plugins::HamlPlugin::RubyParseError) { builder.parenthesized_expression("raise \"foo'", line_no: 12) }

    assert_equal(12, error.line)
    assert_includes(error.message, "Could not parse Haml output script")
    assert_includes(error.message, "Ruby syntax error")
  end

  def test_ruby_builder_reports_parse_errors_for_silent_scripts_with_children
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    error = assert_raises(Klenod::Build::Plugins::HamlPlugin::RubyParseError) { builder.silent_script_with_children("raise \"foo'", builder.expression("H[:p]"), line_no: 12) }

    assert_equal(12, error.line)
    assert_includes(error.message, "Could not parse Haml silent script")
  end

  def test_ruby_builder_reports_parse_errors_for_branches
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    error = assert_raises(Klenod::Build::Plugins::HamlPlugin::RubyParseError) { builder.silent_branches([["if ready )", builder.expression("H[:p]")]], line_no: 12) }

    assert_equal(12, error.line)
    assert_includes(error.message, "Could not parse Haml silent branches")
  end

  def test_ruby_builder_builds_if_branches
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.branches([
        ["if show", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(Prism::IfNode, fragment.node)
    assert_kind_of(Prism::ElseNode, fragment.node.subsequent)
    assert_equal("if show\n  H[:p]\nelse\n  H[:span]\nend", fragment.source)
  end

  def test_ruby_builder_builds_unless_branches
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.branches([["unless hidden", builder.expression("H[:p]")]])

    assert_kind_of(Prism::UnlessNode, fragment.node)
  end

  def test_ruby_builder_returns_silent_branch_children
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.silent_branches([
        ["if show", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(Prism::IfNode, fragment.node)
    assert_equal("if show\n  H[:p]\nelse\n  H[:span]\nend", fragment.source)
  end

  def test_ruby_builder_preserves_returns_inside_silent_branches
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.silent_branches([
        ["if show", builder.silent_script("return")]
      ])

    assert_kind_of(Prism::IfNode, fragment.node)
    assert_includes(fragment.source, "return")
    assert_includes(fragment.source, "nil")
  end

  def test_ruby_builder_returns_children_from_modifier_return
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.silent_script_with_children("return unless show", builder.expression("H[:p]"))

    assert_equal(<<~RUBY.chomp, fragment.source)
      unless show
        return H[:p]
      end
    RUBY
  end

  def test_ruby_builder_returns_children_from_modifier_return_if
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.silent_script_with_children("return if show", builder.expression("H[:p]"))

    assert_equal(<<~RUBY.chomp, fragment.source)
      if show
        return H[:p]
      end
    RUBY
  end

  def test_ruby_builder_returns_children_from_bare_return
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.silent_script_with_children("return", builder.expression("H[:p]"))

    assert_equal("return H[:p]", fragment.source)
  end

  def test_ruby_builder_builds_case_branches
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.branches([
        ["case value", builder.expression("nil")],
        ["when 1", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(Prism::CaseNode, fragment.node)
    assert_equal("case value\nwhen 1\n  H[:p]\nelse\n  H[:span]\nend", fragment.source)
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_branches
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(2, "Visible"), builder.expression("H[:p]"))
    fragment =
      builder.branches([
        ["if show", body],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(Prism::IfNode, fragment.node)
    assert_includes(fragment.source, "# SourceMapMark:2")
    assert_includes(fragment.source, "if show")
  end

  private

  def assert_valid_ruby(source)
    result = Prism.parse(source, partial_script: true)

    assert(result.success?, "Expected valid Ruby:\n#{source}\n#{result.errors.map(&:message).join("\n")}")
  end
end
