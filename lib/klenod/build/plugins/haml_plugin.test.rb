# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../../backtrace_rewriter"
require_relative "../../runtime"
require_relative "../context"

class Klenod::Build::Plugins::HamlPlugin::Test < Minitest::Test
  ModuleId = Klenod::Build::ModuleId
  HAML_FIXTURE_DIR = File.expand_path("__test__/haml", __dir__)

  Dir.glob("#{HAML_FIXTURE_DIR}/*.haml").sort.each do |path|
    fixture_path = path
    basename = File.basename(fixture_path, ".haml")
    test_name = "test_haml_fixture_#{basename.gsub(/[^A-Za-z0-9_]/, "_")}"

    define_method(test_name) do
      expected_path = fixture_path.delete_suffix(".haml") + ".rb"
      actual = transform_haml_fixture(fixture_path)

      unless File.exist?(expected_path)
        warn("Generated #{expected_path}")
        File.write(expected_path, actual)
      end

      assert_equal(File.read(expected_path), actual, "Expected #{expected_path} to match #{fixture_path}")
    end
  end

  module FakeFramework
    class ComponentBase
    end

    module H
      def self.[](tag, *children, **props)
        props = props.compact

        return tag.new(**props, children: children).render if tag.is_a?(Class)

        props.empty? ? [tag, *children] : [tag, *children, props]
      end
    end
  end

  class CapturingTransformer
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(**kwargs)
      @calls << kwargs

      Klenod::Build::Plugins::HamlPlugin::HamlTransformResult.new(
        <<~RUBY,
          class #{kwargs.fetch(:component_class_name)} < #{kwargs.fetch(:component_base_class)}
            H = #{kwargs.fetch(:factory)}
            Translations = #{kwargs.fetch(:translations_source)}

            def render
              [:custom, H]
            end
          end

          Default = #{kwargs.fetch(:component_class_name)}
          Styles = #{kwargs.fetch(:styles_source)}
          Default.const_set(:Styles, Styles)
          Translations = Default::Translations
        RUBY
        :source_map,
        {custom: true},
        nil
      )
    end
  end

  def test_ruby_builder_builds_unmarked_factory_calls_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment =
      builder.factory_call(
        factory: "#{self.class.name}::FakeFramework::H",
        tag: ":p",
        children: ["\"Hello\""],
        props: {class: "\"intro\""}
      )

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(SyntaxTree::ARef, fragment.node)
    assert_includes(fragment.source, "#{self.class.name}::FakeFramework::H[")
    assert_includes(fragment.source, ":p")
    assert_includes(fragment.source, '"Hello"')
    assert_includes(fragment.source, '**{ class: "intro" }')
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_factory_calls
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    child = builder.marked_expression(builder.source_mark(2, "Hello"), builder.expression("\"Hello\""))
    fragment =
      builder.factory_call(
        factory: "#{self.class.name}::FakeFramework::H",
        tag: ":p",
        children: [child],
        props: {class: "\"intro\""},
        mark: builder.source_mark(1, "p")
      )

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(SyntaxTree::ARef, fragment.node)
    assert_includes(fragment.source, "# SourceMapMark:1:")
    assert_includes(fragment.source, "# SourceMapMark:2:")
    assert_includes(fragment.source, "**{")
    assert_includes(fragment.source, "class:")
    assert_includes(fragment.source, '"intro"')
  end

  def test_ruby_builder_fragments_keep_parsed_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    unmarked = builder.expression('H[:p, **{:class => "intro"}]')

    assert_kind_of(SyntaxTree::ARef, unmarked.node)
    assert_equal('H[:p, **{ class: "intro" }]', unmarked.source)
  end

  def test_ruby_builder_program_fragments_keep_parsed_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    program = builder.program("class Page\nend\n")

    assert_kind_of(SyntaxTree::Program, program.node)
    assert_equal("class Page\nend\n", program.source)
  end

  def test_ruby_builder_composes_programs_from_statement_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
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
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
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

  def test_ruby_builder_builds_frozen_literals_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
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
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.import_call("pages/page.haml:companion_style")

    assert_kind_of(SyntaxTree::CallNode, fragment.node)
    assert_equal('__klenod_import__("pages/page.haml:companion_style")', fragment.source)
  end

  def test_ruby_builder_builds_constant_assignments_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.constant_assignment("Default", "Page")

    assert_kind_of(SyntaxTree::Assign, fragment.node)
    assert_equal("Default = Page", fragment.source)
  end

  def test_ruby_builder_builds_method_calls_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    bare_call = builder.call(receiver: nil, name: "method", arguments: [builder.symbol("__klenod_import__")])
    receiver_call = builder.call(receiver: "Default", name: "const_set", arguments: [builder.symbol("Styles"), "Styles"])

    assert_kind_of(SyntaxTree::CallNode, bare_call.node)
    assert_equal("method(:__klenod_import__)", bare_call.source)
    assert_kind_of(SyntaxTree::CallNode, receiver_call.node)
    assert_equal("Default.const_set(:Styles, Styles)", receiver_call.source)
  end

  def test_ruby_builder_builds_method_definitions_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.method_definition("title", body: builder.literal("Hello"))

    assert_kind_of(SyntaxTree::DefNode, fragment.node)
    assert_equal(<<~RUBY.chomp, fragment.source)
      def title
        "Hello"
      end
    RUBY
  end

  def test_ruby_builder_builds_public_method_definitions_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(3, "title"), builder.expression("title"))
    fragment = builder.public_method_definition("render", body: body)

    assert_kind_of(SyntaxTree::Command, fragment.node)
    assert_includes(fragment.source, "public def render")
    assert_includes(fragment.source, "# SourceMapMark:3:")
    assert_includes(fragment.source, "title")
  end

  def test_ruby_builder_wraps_existing_syntax_tree_nodes_as_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    node = SyntaxTree.parse("title.upcase").statements.body.first
    fragment = builder.fragment(node)

    assert_same(node, fragment.node)
    assert(fragment.node?)
    assert_equal([node], fragment.statement_body)
    assert_equal("title.upcase", fragment.source)
  end

  def test_ruby_builder_statement_fragments_expose_statement_body
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.statements("first\nsecond\n")

    assert_kind_of(SyntaxTree::Statements, fragment.node)
    assert_equal(2, fragment.statement_body.length)
  end

  def test_ruby_builder_normalizes_values_into_expression_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    existing = builder.expression("Page")

    assert_same(existing, builder.expression_fragment(existing))

    fragment = builder.expression_fragment("Object")

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(SyntaxTree::VarRef, fragment.node)
    assert_equal("Object", fragment.source)
  end

  def test_ruby_builder_normalizes_values_into_statement_fragments
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    existing = builder.statements("def title\n  \"Hello\"\nend\n")

    assert_same(existing, builder.statements_fragment(existing))

    fragment = builder.statements_fragment("first\nsecond\n")

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(SyntaxTree::Statements, fragment.node)
    assert_equal(2, fragment.statement_body.length)
  end

  def test_ruby_builder_builds_parenthesized_expressions_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.parenthesized_expression("title.upcase")

    assert_kind_of(SyntaxTree::Paren, fragment.node)
    assert_equal("(title.upcase)", fragment.source)
  end

  def test_ruby_builder_builds_hash_expressions_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.hash_expression("{ title: title.upcase }")

    assert_kind_of(SyntaxTree::HashLiteral, fragment.node)
    assert_equal("{ title: title.upcase }", fragment.source)
  end

  def test_ruby_builder_builds_constant_paths_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new

    assert_kind_of(SyntaxTree::ConstRef, builder.constant_path("Page", declaration: true))
    assert_kind_of(SyntaxTree::VarRef, builder.constant_path("Object"))
    assert_kind_of(SyntaxTree::ConstPathRef, builder.constant_path("Framework::Component::Base"))
  end

  def test_ruby_builder_builds_class_skeletons_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.class_skeleton_fragment("Page", "Framework::Component::Base")

    assert_kind_of(SyntaxTree::ClassDeclaration, fragment.node)
    assert_equal("class Page < Framework::Component::Base\nend", fragment.source)
  end

  def test_ruby_builder_component_program_formats_from_syntax_tree_program
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
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
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
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
    assert_includes(fragment.source, "class Page < Object")
    assert_includes(fragment.source, "Translations = {}.freeze")
    assert_includes(fragment.source, "def title")
    assert_includes(fragment.source, "public def render")
  end

  def test_ruby_builder_component_source_returns_component_program_source
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
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

  def test_haml_transform_result_can_be_built_from_ast
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    ast = builder.program("class Page\nend\n")
    result =
      Klenod::Build::Plugins::HamlPlugin::HamlTransformResult.from_ast(
        ast,
        source: "%h1 Hello\n",
        metadata: {custom: true}
      )

    assert_equal(ast.source, result.code)
    assert_same(ast, result.ast)
    assert_kind_of(Klenod::SourceMap::SourceMap, result.source_map)
    assert_equal({custom: true}, result.metadata)
  end

  def test_ruby_builder_marked_expressions_preserve_wrapped_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    child = builder.expression('"Hello"')
    marked = builder.marked_expression(builder.source_mark(1, "Hello"), child)

    assert_kind_of(SyntaxTree::Statements, marked.node)
    assert_equal(child.node, marked.node.body.last)
    assert_kind_of(SyntaxTree::Comment, marked.node.body.first)
    assert_includes(marked.source, "# SourceMapMark:1:")
    assert_includes(marked.source, '"Hello"')
  end

  def test_ruby_builder_builds_empty_expression_lists_from_nil_node
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.expressions([])

    assert_kind_of(SyntaxTree::VarRef, fragment.node)
    assert_equal("nil", fragment.source)
  end

  def test_ruby_builder_builds_nil_expression_from_syntax_tree_node
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.nil_expression

    assert_kind_of(SyntaxTree::VarRef, fragment.node)
    assert_equal("nil", fragment.source)
  end

  def test_ruby_builder_reuses_single_expression_list_fragment
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    child = builder.expression('"Hello"')

    assert_same(child, builder.expressions([child]))
  end

  def test_ruby_builder_builds_unmarked_expression_lists_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment =
      builder.expressions([
        builder.expression('H[:p, "Hello"]'),
        builder.expression('H[:span, "World"]')
      ])

    assert_kind_of(SyntaxTree::ArrayLiteral, fragment.node)
    assert_equal('[H[:p, "Hello"], H[:span, "World"]]', fragment.source)
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_expression_lists
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    child = builder.marked_expression(builder.source_mark(1, "Hello"), builder.expression('"Hello"'))
    fragment = builder.expressions([child, builder.expression('"World"')])

    assert_kind_of(SyntaxTree::ArrayLiteral, fragment.node)
    assert_includes(fragment.source, "# SourceMapMark:1:")
    assert_includes(fragment.source, '"World"')
  end

  def test_ruby_builder_builds_silent_scripts_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment = builder.silent_script("@visible = true")

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    assert_equal(<<~RUBY.chomp, fragment.source)
      begin
        @visible = true
        nil
      end
    RUBY
  end

  def test_ruby_builder_builds_ruby_filters_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment =
      builder.ruby_filters([
        "#{builder.source_mark(2, "def title")}\ndef title\n  \"Hello\"\nend"
      ])

    assert_kind_of(SyntaxTree::Statements, fragment.node)
    assert_includes(fragment.source, "# SourceMapMark:2:")
    assert_includes(fragment.source, "begin\n")
    assert_includes(fragment.source, "def title")
  end

  def test_ruby_builder_builds_script_blocks_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.script_block("items.map do |item|", body)

    assert_kind_of(SyntaxTree::MethodAddBlock, fragment.node)
    assert_equal("items.map { |item| H[:li, item] }", fragment.source)
  end

  def test_ruby_builder_builds_silent_script_blocks_with_nil_result
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    body = builder.expression("H[:li, item]")
    fragment = builder.silent_script_block("items.each do |item|", body)

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    assert_equal(<<~RUBY.chomp, fragment.source)
      begin
        items.each { |item| H[:li, item] }
        nil
      end
    RUBY
  end

  def test_ruby_builder_builds_script_block_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    node = builder.send(:block_script_node, "items.map do |item|", builder.expression("item").node)

    assert_kind_of(SyntaxTree::MethodAddBlock, node)
    assert_kind_of(SyntaxTree::BlockNode, node.block)
    assert_equal("do", node.block.opening.value)
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_script_blocks
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(2, "item"), builder.expression("item"))
    fragment = builder.script_block("items.map do |item|", body)

    assert_kind_of(SyntaxTree::MethodAddBlock, fragment.node)
    assert_includes(fragment.source, "# SourceMapMark:2:")
    assert_includes(fragment.source, "items.map do |item|")
  end

  def test_ruby_builder_builds_if_branches_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment =
      builder.branches([
        ["if show", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(SyntaxTree::IfNode, fragment.node)
    assert_includes(fragment.source, "show")
    assert_includes(fragment.source, "H[:p]")
    assert_includes(fragment.source, "H[:span]")
  end

  def test_ruby_builder_builds_branch_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
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
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment =
      builder.silent_branches([
        ["if show", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    assert_equal(<<~RUBY.chomp, fragment.source)
      begin
        show ? H[:p] : H[:span]
        nil
      end
    RUBY
  end

  def test_ruby_builder_preserves_returns_inside_silent_branches
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment =
      builder.silent_branches([
        ["if show", builder.silent_script("return")]
      ])

    assert_kind_of(SyntaxTree::Begin, fragment.node)
    assert_includes(fragment.source, "return")
    assert_includes(fragment.source, "nil")
  end

  def test_ruby_builder_builds_case_branches_from_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    fragment =
      builder.branches([
        ["case value", builder.expression("nil")],
        ["when 1", builder.expression("H[:p]")],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(SyntaxTree::Case, fragment.node)
    assert_includes(fragment.source, "case value")
    assert_includes(fragment.source, "when 1")
    assert_includes(fragment.source, "H[:p]")
    assert_includes(fragment.source, "else")
    assert_includes(fragment.source, "H[:span]")
  end

  def test_ruby_builder_preserves_source_map_marks_when_composing_branches
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    body = builder.marked_expression(builder.source_mark(2, "Visible"), builder.expression("H[:p]"))
    fragment =
      builder.branches([
        ["if show", body],
        ["else", builder.expression("H[:span]")]
      ])

    assert_kind_of(SyntaxTree::IfNode, fragment.node)
    assert_includes(fragment.source, "# SourceMapMark:2:")
    assert_includes(fragment.source, "if show")
  end

  def test_haml_records_companion_watched_patterns
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")

      assert_equal(
        ["pages/page.css", "pages/page.intl.*.toml"],
        record.watched_patterns.map(&:glob)
      )
      assert_equal({}, context.graph.mods.fetch(record.id).const_get(:Exports)::Styles)
      assert_equal({}, context.graph.mods.fetch(record.id).const_get(:Exports)::Translations)
    end
  end

  def test_haml_generates_configured_component_class
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/hello-world.haml", "%h1 Hello\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          component_base_class: "#{self.class.name}::FakeFramework::ComponentBase",
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/hello-world.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_operator(exports::Default, :<, FakeFramework::ComponentBase)
      assert_equal([:h1, "Hello"], exports::Default.new.render)
      assert_equal(exports::Default::Styles, exports::Styles)
      assert_equal(exports::Default::Translations, exports::Translations)
    end
  end

  def test_default_haml_transformer_result_exposes_component_program_ast
    transformer = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer.new
    result =
      transformer.call(
        source: "%h1 Hello\n",
        module_id: ModuleId.new("pages/page.haml", nil),
        component_class_name: "Page",
        component_base_class: "Object",
        factory: "#{self.class.name}::FakeFramework::H",
        styles_source: "{}.freeze",
        translations_source: "{}.freeze"
      )

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder::Fragment, result.ast)
    assert_kind_of(SyntaxTree::Program, result.ast.node)
    assert_equal(result.code, result.ast.source)
  end

  def test_default_haml_transformer_compiles_template_to_fragments
    transformer = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer.new
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    template =
      transformer.send(
        :compile_template,
        <<~HAML,
          :ruby
            def title
              "Hello"
            end

          %h1= title
        HAML
        factory: "#{self.class.name}::FakeFramework::H",
        builder: builder
      )

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder::Fragment, template.ruby)
    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder::Fragment, template.render)
    assert_kind_of(SyntaxTree::Statements, template.ruby.node)
    assert_kind_of(SyntaxTree::Node, template.render.node)
  end

  def transform_haml_fixture(path)
    basename = File.basename(path, ".haml")
    module_id = ModuleId.new("__test__/haml/#{File.basename(path)}", nil)
    styles_source =
      if basename == "style_classes"
        "{__figure: \"figure_hash\", __img: \"img_hash\", card: \"card_hash\", image: \"image_hash\"}.freeze"
      else
        "{}.freeze"
      end

    Klenod::Build::Plugins::HamlPlugin::DefaultTransformer
      .new
      .call(
        source: File.read(path),
        module_id: module_id,
        component_class_name: basename.split(/[^A-Za-z0-9]+/).map { it[0].upcase + it[1..] }.join,
        component_base_class: "TestFramework::ComponentBase",
        factory: "TestFramework::H",
        styles_source: styles_source,
        translations_source: "{}.freeze",
        styleable: basename == "style_classes"
      )
      .code
  end

  def default_plugins_with(plugin)
    Klenod::Build::Context::DEFAULT_PLUGINS.map do |default_plugin|
      default_plugin.is_a?(Klenod::Build::Plugins::HamlPlugin) ? plugin : default_plugin
    end
  end

  def test_default_haml_transformer_compiles_ruby_filter_to_statement_fragment
    transformer = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer.new
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    parsed = SyntaxTree::Haml.parse(<<~HAML)
      :ruby
        def title
          "Hello"
        end
    HAML
    fragment = transformer.send(:compile_ruby_filter, parsed.children.fetch(0), builder: builder)

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder::Fragment, fragment)
    assert_kind_of(SyntaxTree::Statements, fragment.node)
    assert_kind_of(SyntaxTree::Comment, fragment.node.body.first)
    assert_includes(fragment.source, "SourceMapMark:2:")
  end

  def test_default_haml_transformer_renders_with_configured_factory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          %main{ class: "shell".upcase }
            %h1 Hello
            %p= "From Ruby"
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:main, [:h1, "Hello"], [:p, "From Ruby"], {class: "SHELL"}], exports::Default.new.render)
      assert_kind_of(Klenod::SourceMap::SourceMap, record.source_map)
    end
  end

  def test_default_haml_transformer_supports_dynamic_attribute_fragments
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def title
              "hello"
            end

          %p{ title: title.upcase } Hello
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:p, "Hello", {title: "HELLO"}], exports::Default.new.render)
      assert_includes(record.transformed_source, "title:")
      assert_includes(record.transformed_source, "title.upcase")
    end
  end

  def test_default_haml_transformer_maps_object_reference_to_key_prop
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            User = Data.define(:id)

            def initialize
              @user = User.new(15)
            end

          %div[@user, :greeting] Hello
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:div, "Hello", {key: [exports::Default::User.new(15), :greeting]}], exports::Default.new.render)
      assert_includes(record.transformed_source, "key:")
      assert_includes(record.transformed_source, "[@user, :greeting]")
    end
  end

  def test_default_haml_transformer_maps_component_object_reference_to_key_prop
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/components")
      File.write(
        "#{dir}/components/card.haml",
        <<~HAML
          :ruby
            def initialize(key:, children: nil)
              @key = key
              @children = children
            end

          %article
            = @key
            = @children
        HAML
      )
      File.write(
        "#{dir}/page.haml",
        <<~HAML
          :ruby
            Card = import("components/card.haml")
            User = Data.define(:id)

            def initialize
              @user = User.new(15)
            end

          %Card[@user]
            Hello
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [Klenod::Build::Plugins::RubyPlugin.new, plugin])
      record = context.evaluate("page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      user = exports::Default::User.new(15)

      assert_equal([:article, user, ["Hello"]], exports::Default.new.render)
    end
  end

  def test_default_haml_transformer_supports_parsed_inline_tag_values
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def title
              "Hello"
            end

          %p= title
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:p, "Hello"], exports::Default.new.render)
      assert_includes(record.transformed_source, "(title)")
    end
  end

  def test_default_haml_transformer_maps_inner_whitespace_marker_to_left_space
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%a{ href: \"#\" }< link\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([" ", [:a, "link", {href: "#"}]], exports::Default.new.render)
    end
  end

  def test_default_haml_transformer_maps_outer_whitespace_marker_to_right_space
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%a{ href: \"#\" }> link\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([[:a, "link", {href: "#"}], " "], exports::Default.new.render)
    end
  end

  def test_default_haml_transformer_maps_both_whitespace_markers
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%a{ href: \"#\" }<> link\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([" ", [:a, "link", {href: "#"}], " "], exports::Default.new.render)
    end
  end

  def test_default_haml_transformer_maps_whitespace_markers_around_nested_tag
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          %p
            before
            %a{ href: "#" }<> link
            after
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:p, "before", " ", [:a, "link", {href: "#"}], " ", "after"], exports::Default.new.render)
    end
  end

  def test_default_haml_transformer_supports_ruby_filter_and_attributes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/handlers.haml",
        <<~HAML
          :ruby
            def handle_click
              :clicked
            end

          %button{ onclick: handle_click } Click me
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          component_base_class: "#{self.class.name}::FakeFramework::ComponentBase",
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/handlers.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_operator(exports::Default, :<, FakeFramework::ComponentBase)
      assert_equal([:button, "Click me", {onclick: :clicked}], exports::Default.new.render)
      assert_match(/SourceMapMark:2:/, record.transformed_source)
      assert_match(/SourceMapMark:6:/, record.transformed_source)
    end
  end

  def test_default_haml_transformer_supports_script_blocks_with_children
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/list.haml",
        <<~HAML
          :ruby
            Item = Data.define(:name)

            def initialize
              @items = [Item.new("A"), Item.new("B")]
            end

          %ul
            = @items.map do |item|
              %li= item.name
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/list.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:ul, [[:li, "A"], [:li, "B"]]], exports::Default.new.render)
      assert_match(/SourceMapMark:8:/, record.transformed_source)
      assert_match(/SourceMapMark:9:/, record.transformed_source)
    end
  end

  def test_default_haml_transformer_supports_silent_script_blocks_with_children
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/list.haml",
        <<~HAML
          :ruby
            Item = Data.define(:name)

            def initialize
              @items = [Item.new("A"), Item.new("B")]
              @seen = []
            end

            def seen
              @seen
            end

          %ul
            - @items.each do |item|
              - @seen << item.name
              %li= item.name
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/list.haml")
      component = context.graph.mods.fetch(record.id).const_get(:Exports)::Default.new

      assert_equal([:ul, nil], component.render)
      assert_equal(["A", "B"], component.seen)
      assert_match(/SourceMapMark:12:/, record.transformed_source)
      assert_match(/SourceMapMark:13:/, record.transformed_source)
    end
  end

  def test_default_haml_transformer_supports_silent_control_flow
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/conditional.haml",
        <<~HAML
          :ruby
            def initialize(show:)
              @show = show
            end

          - if @show
            %p Visible
          - else
            %p Empty
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/conditional.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_nil(exports::Default.new(show: true).render)
      assert_nil(exports::Default.new(show: false).render)
      assert_match(/SourceMapMark:7:/, record.transformed_source)
      assert_match(/SourceMapMark:9:/, record.transformed_source)
    end
  end

  def test_default_haml_transformer_supports_output_control_flow
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/conditional.haml",
        <<~HAML
          :ruby
            def initialize(show:)
              @show = show
            end

          %section
            = if @show
              %p Visible
            = else
              %p Empty
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/conditional.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:section, [:p, "Visible"]], exports::Default.new(show: true).render)
      assert_equal([:section, [:p, "Empty"]], exports::Default.new(show: false).render)
      assert_match(/SourceMapMark:8:/, record.transformed_source)
      assert_match(/SourceMapMark:10:/, record.transformed_source)
    end
  end

  def test_default_haml_transformer_supports_output_control_flow_without_else
    plugin =
      Klenod::Build::Plugins::HamlPlugin.new(
        factory: "#{self.class.name}::FakeFramework::H"
      )
    context = Klenod::Build::Context.new(source_dir: File.expand_path("__test__", __dir__), plugins: [plugin])
    record = context.evaluate("haml/output_conditional_without_else.haml")
    exports = context.graph.mods.fetch(record.id).const_get(:Exports)

    assert_equal([:section, [:p, "Visible"]], exports::Default.new(show: true).render)
    assert_equal([:section, nil], exports::Default.new(show: false).render)
    assert_match(/SourceMapMark:8:/, record.transformed_source)
  end

  def test_haml_imports_haml_component_classes_for_capitalized_tags
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/components")
      File.write(
        "#{dir}/components/details.haml",
        <<~HAML
          :ruby
            def initialize(summary:, children: nil)
              @summary = summary
              @children = children
            end

          %details
            %summary= @summary
            = @children
        HAML
      )
      File.write(
        "#{dir}/page.haml",
        <<~HAML
          :ruby
            Details = import("components/details.haml")

          %Details{ summary: "Mer information" }
            %p Lorem ipsum
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [Klenod::Build::Plugins::RubyPlugin.new, plugin])
      record = context.evaluate("page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      details_class = context.graph.mods.fetch(ModuleId.new("components/details.haml", nil)).const_get(:Exports)::Default

      assert_same(details_class, exports::Default.const_get(:Details))
      assert_equal(
        [
          :details,
          [:summary, "Mer information"],
          [[:p, "Lorem ipsum"]]
        ],
        exports::Default.new.render
      )
    end
  end

  def test_default_haml_transformer_rewrites_error_backtraces_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          %main
            %h1 Hello
            = raise "boom"
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:3:in /, error.backtrace.fetch(0))
    end
  end

  def test_default_haml_transformer_rewrites_ruby_filter_errors_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def explode
              raise "filter boom"
            end

          %main
            = explode
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:3:in /, error.backtrace.fetch(0))
    end
  end

  def test_default_haml_transformer_rewrites_nested_script_errors_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def initialize
              @items = [1, 2]
            end

          %ul
            = @items.map do |item|
              %li= raise "nested boom" if item == 2
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:8:in /, error.backtrace.fetch(0))
    end
  end

  def test_default_haml_transformer_rewrites_dynamic_attribute_errors_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          %main{ class: (raise "class boom") }
            %h1 Hello
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:1:in /, error.backtrace.fetch(0))
    end
  end

  def test_default_haml_transformer_rewrites_ruby_filter_method_called_from_markup
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def title
              raise "title boom"
            end

          %main
            %h1= title
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:3:in /, error.backtrace.fetch(0))
    end
  end

  def test_default_haml_transformer_rewrites_imported_component_render_errors_to_component_haml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/components")
      File.write(
        "#{dir}/components/details.haml",
        <<~HAML
          :ruby
            def initialize(children: nil)
            end

          %section
            %h2 Details
            = raise "details boom"
        HAML
      )
      File.write(
        "#{dir}/page.haml",
        <<~HAML
          :ruby
            Details = import("components/details.haml")

          %main
            %Details
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      page_record = context.evaluate("page.haml")
      page_mod = context.graph.mods.fetch(page_record.id)
      details_mod = context.graph.mods.fetch(ModuleId.new("components/details.haml", nil))
      exports = page_mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::BacktraceRewriter
        .new(
          {
            "page.haml" => page_mod,
            "components/details.haml" => details_mod
          }
        )
        .rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/components/details.haml")}:7:in /, error.backtrace.fetch(0))
    end
  end

  def test_default_haml_transformer_rewrites_line_constants_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def filter_line
              __LINE__
            end

          %main{ data_line: __LINE__ }
            = __LINE__
            = filter_line
            = "__LINE__"
            %span= __LINE__
            %section[__LINE__]
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.exports(record)

      assert_equal([:main, 7, 3, "__LINE__", [:span, 10], [:section, {key: 11}], {data_line: 6}], exports::Default.new.render)
    end
  end

  def test_haml_uses_custom_transformer_contract
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/custom.haml", "%h1 Custom\n")

      transformer = CapturingTransformer.new
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          component_base_class: "#{self.class.name}::FakeFramework::ComponentBase",
          factory: "#{self.class.name}::FakeFramework::H",
          transformer: transformer
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/custom.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      call = transformer.calls.fetch(0)

      assert_equal("%h1 Custom\n", call.fetch(:source))
      assert_equal(ModuleId.new("pages/custom.haml", nil), call.fetch(:module_id))
      assert_equal("Custom", call.fetch(:component_class_name))
      assert_equal("#{self.class.name}::FakeFramework::ComponentBase", call.fetch(:component_base_class))
      assert_equal("#{self.class.name}::FakeFramework::H", call.fetch(:factory))
      assert_equal("{}.freeze", call.fetch(:styles_source))
      assert_equal("{}.freeze", call.fetch(:translations_source))
      assert_equal([:custom, FakeFramework::H], exports::Default.new.render)
      assert_equal(:source_map, record.source_map)
    end
  end

  def test_haml_loads_companion_intl_files_into_translations
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write("#{dir}/pages/page.intl.en-US.toml", "title = \"Hello\"\n[count]\nvalue = 1\n")
      File.write("#{dir}/pages/page.intl.sv-SE.toml", "title = \"Hej\"\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("pages/page.haml")
      translations = context.graph.mods.fetch(record.id).const_get(:Exports)::Translations

      assert_equal("Hello", translations.fetch("en-US").fetch("title"))
      assert_equal(1, translations.fetch("en-US").fetch("count").fetch("value"))
      assert_equal("Hej", translations.fetch("sv-SE").fetch("title"))
      assert(translations.frozen?)
      assert(translations.fetch("en-US").frozen?)
    end
  end

  def test_haml_runtime_bundle_preserves_translations
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write("#{dir}/pages/page.intl.en-US.toml", "title = \"Hello\"\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      context.build(entrypoints: ["pages/page.haml"], output: output)
      mod = Klenod::Runtime.load_bundle(output).load("pages/page.haml")
      translations = mod.const_get(:Exports)::Translations

      assert_equal("Hello", translations.fetch("en-US").fetch("title"))
    end
  end

  def test_adding_companion_css_reloads_haml_and_imports_styles
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      haml_record = context.evaluate("pages/page.haml")

      assert_equal({}, context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles)

      File.write(css_path, ".title { color: red; }\n")
      result = context.invalidate_paths([css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_match(/title/, styles.fetch(:title))
      assert(context.graph.records.key?(ModuleId.new("pages/page.css", nil)))
    end
  end

  def test_haml_css_filter_loads_as_virtual_css_module
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :css
            .title { color: red; }

          %h1 Hello
        HAML
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")
      virtual_css_id = ModuleId.new("pages/page.haml.inline.0.css", nil)
      css_record = context.graph.records.fetch(virtual_css_id)
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal([virtual_css_id], haml_record.resolved_dependencies.map(&:module_id))
      assert_match(/title/, styles.fetch(:title))
      assert_equal(1, css_record.assets.length)
      assert_match(%r{\A/assets/pages_page_haml_inline_0_css\.[a-f0-9]{16}\.css\z}, css_record.assets.first.output_path)
      assert_includes(css_record.assets.first.bytes, "color: red")
    end
  end

  def test_haml_applies_css_tag_selector_to_matching_tag
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.css", "figure { margin: 0; }\n")
      File.write("#{dir}/pages/page.haml", "%figure Hello\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      haml_record = context.evaluate("pages/page.haml")
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      rendered = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Default.new.render

      assert_match(/figure/, styles.fetch(:__figure))
      assert_equal([:figure, "Hello", {class: styles.fetch(:__figure)}], rendered)
    end
  end

  def test_haml_applies_css_class_selector_to_class_shorthand
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.css", ".image { display: block; }\nimg { width: 100%; }\n")
      File.write("#{dir}/pages/page.haml", "%img.image\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      haml_record = context.evaluate("pages/page.haml")
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      rendered = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Default.new.render

      assert_equal([styles.fetch(:__img), styles.fetch(:image)].join(" "), rendered.fetch(1).fetch(:class))
    end
  end

  def test_haml_joins_duplicate_class_names_from_companion_and_inline_css
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.css", ".title { color: red; }\n")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :css
            .title { color: blue; }

          %h1 Hello
        HAML
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      title_classes = styles.fetch(:title).split

      assert_equal(
        [ModuleId.new("pages/page.css", nil), ModuleId.new("pages/page.haml.inline.0.css", nil)],
        haml_record.resolved_dependencies.map(&:module_id)
      )
      assert_equal(2, title_classes.length)
      assert(title_classes.all? { |class_name| class_name.include?("title") })
      assert_equal(title_classes.uniq, title_classes)
    end
  end

  def test_removing_haml_css_filter_removes_virtual_css_module
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      haml_path = "#{dir}/pages/page.haml"
      File.write(
        haml_path,
        <<~HAML
          :css
            .title { color: red; }

          %h1 Hello
        HAML
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")
      virtual_css_id = ModuleId.new("pages/page.haml.inline.0.css", nil)

      assert(context.graph.records.key?(virtual_css_id))

      File.write(haml_path, "%h1 Hello\n")
      result = context.invalidate_paths([haml_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      refute(context.graph.records.key?(virtual_css_id))
      assert_equal({}, styles)
    end
  end

  def test_editing_companion_intl_reloads_haml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hello\"\n")
      result = context.invalidate_paths([intl_path])

      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(1, context.graph.records.fetch(haml_record.id).version)
    end
  end

  def test_editing_companion_css_reloads_haml_and_updates_styles
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write(css_path, ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")
      old_asset_path = context.graph.records.fetch(ModuleId.new("pages/page.css", nil)).assets.first.output_path
      old_styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      File.write(css_path, ".heading { color: blue; }\n")
      result = context.invalidate_paths([css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      css_record = context.graph.records.fetch(ModuleId.new("pages/page.css", nil))

      assert_equal(["pages/page.css", "pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_match(/title/, old_styles.fetch(:title))
      refute_includes(styles.keys, :title)
      assert_match(/heading/, styles.fetch(:heading))
      refute_equal(old_asset_path, css_record.assets.first.output_path)
      assert_includes(css_record.assets.first.bytes, "color: #00f")
    end
  end

  def test_adding_editing_and_removing_companion_intl_reloads_haml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hello\"\n")
      add_result = context.invalidate_paths([intl_path])
      File.write(intl_path, "title = \"Hi\"\n")
      edit_result = context.invalidate_paths([intl_path])
      File.delete(intl_path)
      remove_result = context.invalidate_paths([], removed_paths: [intl_path])

      assert_equal(["pages/page.haml"], add_result.reloaded_module_ids.map(&:to_s))
      assert_equal(["pages/page.haml"], edit_result.reloaded_module_ids.map(&:to_s))
      assert_equal(["pages/page.haml"], remove_result.reloaded_module_ids.map(&:to_s))
      assert_equal(3, context.graph.records.fetch(haml_record.id).version)
    end
  end

  def test_editing_companion_intl_updates_translations
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write(intl_path, "title = \"Hello\"\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hi\"\n")
      context.invalidate_paths([intl_path])
      translations = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Translations

      assert_equal("Hi", translations.fetch("en-US").fetch("title"))
    end
  end

  def test_malformed_companion_intl_reports_load_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hello\"\ninvalid =\n")
      result = context.invalidate_paths([intl_path])

      assert_equal(["pages/page.haml"], result.errors.map { |module_id, _error| module_id.to_s })
      assert_kind_of(TomlRB::ParseError, result.errors.first.last)
    end
  end

  def test_removing_companion_css_reloads_haml_back_to_empty_styles
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write(css_path, ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")

      assert_match(/title/, context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles.fetch(:title))

      File.delete(css_path)
      result = context.invalidate_paths([], removed_paths: [css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(["pages/page.css"], result.removed_module_ids.map(&:to_s))
      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_equal({}, styles)
    end
  end
end
