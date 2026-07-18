# frozen_string_literal: true

require_relative "../haml_plugin_test_support"

class Klenod::Build::Plugins::HamlPlugin::RubyBuilderTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_ruby_builder_builds_unmarked_factory_calls_from_syntax_tree_nodes
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
    assert_includes(fragment.source, '**{ class: "intro" }')
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
    assert_includes(fragment.source, "**{")
    assert_includes(fragment.source, "class:")
    assert_includes(fragment.source, '"intro"')
  end

  def test_ruby_builder_fragments_keep_parsed_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    unmarked = builder.expression('H[:p, **{:class => "intro"}]')

    assert_kind_of(SyntaxTree::ARef, unmarked.node)
    assert_equal('H[:p, **{:class => "intro"}]', unmarked.source)
    assert_equal('H[:p, **{ class: "intro" }]', builder.fragment(unmarked.node).source)
  end

  def test_ruby_builder_program_fragments_keep_parsed_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    program = builder.program("class Page\nend\n")

    assert_kind_of(SyntaxTree::Program, program.node)
    assert_equal("class Page\nend\n", program.source)
  end

  def test_ruby_builder_composes_programs_from_statement_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    program =
      builder.program_from_fragments(
        builder.statements("# frozen_string_literal: true\n\nKlenodImport = nil\n"),
        builder.statements("class Page\nend\n"),
        builder.statements("Default = Page\n")
      )

    assert_kind_of(SyntaxTree::Program, program.node)
    assert_equal(
      [SyntaxTree::Comment, SyntaxTree::Assign, SyntaxTree::ClassDeclaration, SyntaxTree::Assign],
      program.node.statements.body.map(&:class)
    )
    assert_includes(program.source, "# frozen_string_literal: true")
    assert_includes(program.source, "class Page")
    assert_includes(program.source, "Default = Page")
  end

  def test_ruby_builder_literals_and_symbols_keep_parsed_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    literal = builder.literal("Hello")
    escaped_literal = builder.literal("\#{title}")
    integer = builder.literal(123)
    truthy = builder.literal(true)
    symbol = builder.symbol("p")
    dashed_symbol = builder.symbol("article-card")

    assert_kind_of(SyntaxTree::StringLiteral, literal.node)
    assert_equal('"Hello"', literal.source)
    assert_kind_of(SyntaxTree::StringLiteral, escaped_literal.node)
    assert_equal('"\\#{title}"', escaped_literal.source)
    assert_kind_of(SyntaxTree::Int, integer.node)
    assert_equal("123", integer.source)
    assert_kind_of(SyntaxTree::VarRef, truthy.node)
    assert_equal("true", truthy.source)
    assert_kind_of(SyntaxTree::SymbolLiteral, symbol.node)
    assert_equal(":p", symbol.source)
    assert_kind_of(SyntaxTree::DynaSymbol, dashed_symbol.node)
    assert_equal(':"article-card"', dashed_symbol.source)
  end

  def test_ruby_builder_reuses_short_string_literals
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    assert_same(builder.literal(" "), builder.literal(" "))
    refute_same(builder.literal("Hello"), builder.literal("Hello"))
  end

  def test_ruby_builder_builds_frozen_literals_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    literal =
      builder.frozen_literal(
        {
          "en-US" => {
            "title" => "Hello",
            "items" => [1, 2]
          }
        }
      )

    assert_kind_of(SyntaxTree::CallNode, literal.node)
    assert_includes(literal.source, '"en-US"')
    assert_includes(literal.source, '"title" => "Hello"')
    assert_includes(literal.source, "[1, 2].freeze")
    assert_includes(literal.source, ".freeze")
  end

  def test_ruby_builder_builds_import_calls_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.import_call("pages/page.haml:companion_style")

    assert_kind_of(SyntaxTree::CallNode, fragment.node)
    assert_equal('__klenod_import__("pages/page.haml:companion_style")', fragment.source)
  end

  def test_ruby_builder_builds_style_lookup_helpers_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    tag_lookup = builder.styles_lookup("__p")
    class_lookup = builder.class_name_lookup("article-card")
    class_names = builder.class_names([tag_lookup, class_lookup, builder.expression("dynamic_class")])

    assert_kind_of(SyntaxTree::ARef, tag_lookup.node)
    assert_equal("Styles[:__p]", tag_lookup.source)
    assert_kind_of(SyntaxTree::Binary, class_lookup.node)
    assert_equal('Styles[:"article-card"] || "article-card"', class_lookup.source)
    assert_kind_of(SyntaxTree::CallNode, class_names.node)

    formatted = builder.fragment(class_names.node).source
    assert_includes(formatted, "Klenod::Runtime.class_names(")
    assert_includes(formatted, "Styles[:__p]")
    assert_includes(formatted, 'Styles[:"article-card"] || "article-card"')
    assert_includes(formatted, "dynamic_class")
  end

  def test_ruby_builder_builds_constant_assignments_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.constant_assignment("Default", "Page")

    assert_kind_of(SyntaxTree::Assign, fragment.node)
    assert_equal("Default = Page", builder.fragment(fragment.node).source)
  end

  def test_ruby_builder_builds_method_calls_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    bare_call = builder.call(receiver: nil, name: "method", arguments: [builder.symbol("__klenod_import__")])
    receiver_call = builder.call(receiver: "Default", name: "const_set", arguments: [builder.symbol("Styles"), "Styles"])

    assert_kind_of(SyntaxTree::CallNode, bare_call.node)
    assert_equal("method(:__klenod_import__)", builder.fragment(bare_call.node).source)
    assert_kind_of(SyntaxTree::CallNode, receiver_call.node)
    assert_equal("Default.const_set(:Styles, Styles)", builder.fragment(receiver_call.node).source)
  end

  def test_ruby_builder_builds_method_definitions_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.method_definition("title", body: builder.literal("Hello"))

    assert_kind_of(SyntaxTree::DefNode, fragment.node)
    assert_equal(<<~RUBY.chomp, builder.fragment(fragment.node).source)
      def title
        "Hello"
      end
    RUBY
  end

  def test_ruby_builder_builds_public_method_definitions_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(3, "title"), builder.expression("title"))
    fragment = builder.public_method_definition("render", body: body)

    assert_kind_of(SyntaxTree::Command, fragment.node)
    formatted = builder.fragment(fragment.node).source
    assert_includes(formatted, "public def render")
    assert_includes(formatted, "# SourceMapMark:3")
    assert_includes(formatted, "title")
  end

  def test_ruby_builder_wraps_existing_syntax_tree_nodes_as_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    node = SyntaxTree.parse("title.upcase").statements.body.first
    fragment = builder.fragment(node)

    assert_same(node, fragment.node)
    assert(fragment.node?)
    assert_equal([node], fragment.statement_body)
    assert_equal("title.upcase", fragment.source)
  end

  def test_ruby_builder_statement_fragments_expose_statement_body
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.statements("first\nsecond\n")

    assert_kind_of(SyntaxTree::Statements, fragment.node)
    assert_equal(2, fragment.statement_body.length)
  end

  def test_ruby_builder_normalizes_values_into_expression_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    existing = builder.expression("Page")

    assert_same(existing, builder.expression_fragment(existing))

    fragment = builder.expression_fragment("Object")

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(SyntaxTree::VarRef, fragment.node)
    assert_equal("Object", fragment.source)
  end

  def test_ruby_builder_normalizes_values_into_statement_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    existing = builder.statements("def title\n  \"Hello\"\nend\n")

    assert_same(existing, builder.statements_fragment(existing))

    fragment = builder.statements_fragment("first\nsecond\n")

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(SyntaxTree::Statements, fragment.node)
    assert_equal(2, fragment.statement_body.length)
  end

  def test_ruby_builder_builds_parenthesized_expressions_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.parenthesized_expression("title.upcase")

    assert_kind_of(SyntaxTree::Paren, fragment.node)
    assert_equal("(title.upcase)", fragment.source)
  end

  def test_ruby_builder_builds_hash_expressions_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.hash_expression("{ title: title.upcase }")

    assert_kind_of(SyntaxTree::HashLiteral, fragment.node)
    assert_equal("{ title: title.upcase }", fragment.source)
  end

  def test_ruby_builder_builds_constant_paths_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new

    assert_kind_of(SyntaxTree::ConstRef, builder.constant_path("Page", declaration: true))
    assert_kind_of(SyntaxTree::VarRef, builder.constant_path("Object"))
    assert_kind_of(SyntaxTree::ConstPathRef, builder.constant_path("Framework::Component::Base"))
  end

  def test_ruby_builder_builds_class_skeletons_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.class_skeleton_fragment("Page", "Framework::Component::Base")

    assert_kind_of(SyntaxTree::ClassDeclaration, fragment.node)
    assert_equal("class Page < Framework::Component::Base\nend", builder.fragment(fragment.node).source)
  end

  def test_ruby_builder_component_program_formats_from_syntax_tree_program
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

    assert_kind_of(SyntaxTree::Program, program.node)
    assert_includes(program.node.statements.body.map(&:class), SyntaxTree::ClassDeclaration)
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
        ruby_source: builder.statements_fragment("def title\n  \"Hello\"\nend\n"),
        render_source: builder.expression_fragment("title")
      )

    assert_kind_of(SyntaxTree::ClassDeclaration, fragment.node)
    assert_kind_of(SyntaxTree::Assign, fragment.node.bodystmt.statements.body.fetch(1))
    formatted = builder.fragment(fragment.node).source
    assert_includes(formatted, "class Page < Object")
    assert_includes(formatted, "Translations = {}.freeze")
    assert_includes(formatted, "def title")
    assert_includes(formatted, "public def render")
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

  def test_ruby_builder_marked_expressions_preserve_wrapped_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    child = builder.expression('"Hello"')
    marked = builder.marked_expression(builder.source_mark(1, "Hello"), child)

    assert_kind_of(SyntaxTree::Statements, marked.node)
    assert_equal(child.node, marked.node.body.last)
    assert_kind_of(SyntaxTree::Comment, marked.node.body.first)
    assert_includes(marked.source, "# SourceMapMark:1")
    assert_includes(marked.source, '"Hello"')
  end

  def test_ruby_builder_builds_empty_expression_lists_from_nil_node
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.expressions([])

    assert_kind_of(SyntaxTree::VarRef, fragment.node)
    assert_equal("nil", fragment.source)
  end

  def test_ruby_builder_builds_nil_expression_from_syntax_tree_node
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.nil_expression

    assert_kind_of(SyntaxTree::VarRef, fragment.node)
    assert_equal("nil", fragment.source)
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
  end

  def test_ruby_builder_builds_silent_scripts_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment = builder.silent_script("@visible = true")

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    assert_equal(<<~RUBY.chomp, formatted_source(builder, fragment))
      begin
        @visible = true
        nil
      end
    RUBY
  end

  def test_ruby_builder_builds_ruby_filters_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.ruby_filters([
        "#{builder.source_mark(2, "def title")}\ndef title\n  \"Hello\"\nend"
      ])

    assert_kind_of(SyntaxTree::Statements, fragment.node)
    formatted = formatted_source(builder, fragment)
    assert_includes(formatted, "# SourceMapMark:2")
    assert_includes(formatted, "begin\n")
    assert_includes(formatted, "def title")
  end

  def test_ruby_builder_builds_script_blocks_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.script_block("items.map do |item|", body)

    assert_kind_of(SyntaxTree::MethodAddBlock, fragment.node)
    assert_equal("items.map { |item| H[:li, item] }", formatted_source(builder, fragment))
  end

  def test_ruby_builder_builds_brace_script_blocks_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.script_block("items.map { |item|", body)

    assert_kind_of(SyntaxTree::MethodAddBlock, fragment.node)
    assert_equal("items.map { |item| H[:li, item] }", formatted_source(builder, fragment))
  end

  def test_ruby_builder_builds_silent_script_blocks_with_nil_result
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.silent_script_block("items.each do |item|", body)

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    assert_equal(<<~RUBY.chomp, formatted_source(builder, fragment))
      begin
        items.each { |item| H[:li, item] }
        nil
      end
    RUBY
  end

  def test_ruby_builder_builds_silent_brace_script_blocks_with_nil_result
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.silent_script_block("items.each { |item|", body)

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    assert_equal(<<~RUBY.chomp, formatted_source(builder, fragment))
      begin
        items.each { |item| H[:li, item] }
        nil
      end
    RUBY
  end

  def test_ruby_builder_builds_script_block_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    node = builder.send(:block_script_node, "items.map do |item|", builder.expression("item").node)

    assert_kind_of(SyntaxTree::MethodAddBlock, node)
    assert_kind_of(SyntaxTree::BlockNode, node.block)
    assert_equal("do", node.block.opening.value)
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_script_blocks
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(2, "item"), builder.expression("item"))
    fragment = builder.script_block("items.map do |item|", body)

    assert_kind_of(SyntaxTree::MethodAddBlock, fragment.node)
    formatted = formatted_source(builder, fragment)
    assert_includes(formatted, "# SourceMapMark:2")
    assert_includes(formatted, "items.map do |item|")
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

  def test_ruby_builder_builds_if_branches_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.branches([
        ["if show", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(SyntaxTree::IfNode, fragment.node)
    formatted = formatted_source(builder, fragment)
    assert_includes(formatted, "show")
    assert_includes(formatted, "H[:p]")
    assert_includes(formatted, "H[:span]")
  end

  def test_ruby_builder_builds_branch_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    node =
      builder.send(
        :branch_node,
        [
          ["if show", builder.expression("H[:p]")],
          ["else", builder.expression("H[:span]")]
        ]
      )

    assert_kind_of(SyntaxTree::IfNode, node)
    assert_kind_of(SyntaxTree::Else, node.consequent)
  end

  def test_ruby_builder_builds_silent_branches_with_nil_result
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.silent_branches([
        ["if show", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    assert_equal(<<~RUBY.chomp, formatted_source(builder, fragment))
      begin
        show ? H[:p] : H[:span]
        nil
      end
    RUBY
  end

  def test_ruby_builder_preserves_returns_inside_silent_branches
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.silent_branches([
        ["if show", builder.silent_script("return")]
      ])

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    formatted = formatted_source(builder, fragment)
    assert_includes(formatted, "return")
    assert_includes(formatted, "nil")
  end

  def test_ruby_builder_builds_case_branches_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    fragment =
      builder.branches([
        ["case value", builder.expression("nil")],
        ["when 1", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(SyntaxTree::Case, fragment.node)
    formatted = formatted_source(builder, fragment)
    assert_includes(formatted, "case value")
    assert_includes(formatted, "when 1")
    assert_includes(formatted, "H[:p]")
    assert_includes(formatted, "else")
    assert_includes(formatted, "H[:span]")
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_branches
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(2, "Visible"), builder.expression("H[:p]"))
    fragment =
      builder.branches([
        ["if show", body],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(SyntaxTree::IfNode, fragment.node)
    formatted = formatted_source(builder, fragment)
    assert_includes(formatted, "# SourceMapMark:2")
    assert_includes(formatted, "if show")
  end

  private

  def formatted_source(builder, fragment)
    builder.fragment(fragment.node).source
  end
end
