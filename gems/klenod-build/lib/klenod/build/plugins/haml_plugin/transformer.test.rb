# frozen_string_literal: true

require_relative "../haml_test_support"

class Klenod::Build::Plugins::HamlPlugin::TransformerTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_transformer_result_exposes_component_program_ast
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
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

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, result.ast)
    assert_kind_of(SyntaxTree::Program, result.ast.node)
    assert_equal(result.code, result.ast.source)
  end

  def test_haml_transformer_compiles_template_to_fragments
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
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

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, template.ruby)
    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, template.render)
    assert_kind_of(SyntaxTree::Statements, template.ruby.node)
    assert_nil(template.render.node)
  end

  def test_haml_transformer_wraps_parse_errors_with_source_context
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
    source = <<~HAML
      %p Before
      %time(datetime=post.fetch("date"))= post.fetch("date")
      %p After
    HAML
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        transformer.call(
          source: source,
          module_id: ModuleId.new("pages/demo/blog/page.haml", nil),
          component_class_name: "Page",
          component_base_class: "Object",
          factory: "#{self.class.name}::FakeFramework::H",
          styles_source: "{}.freeze",
          translations_source: "{}.freeze"
        )
      end

    assert_equal(ModuleId.new("pages/demo/blog/page.haml", nil), error.module_id)
    assert_equal(2, error.line)
    assert_includes(error.message, "pages/demo/blog/page.haml:2: Haml parse error")
    assert_includes(error.message, "Invalid attribute list")
    assert_includes(error.message, "> 2 | %time(datetime=post.fetch(\"date\"))= post.fetch(\"date\")")
    assert_kind_of(::Haml::SyntaxError, error.cause)
  end

  def test_haml_transformer_reports_ruby_script_parse_errors_on_source_line
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
    source = <<~HAML
      %table
        = @columns.map { |column| )
          %th= column
    HAML
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        transformer.call(
          source: source,
          module_id: ModuleId.new("components/DataTable.haml", nil),
          component_class_name: "DataTable",
          component_base_class: "Object",
          factory: "#{self.class.name}::FakeFramework::H",
          styles_source: "{}.freeze",
          translations_source: "{}.freeze"
        )
      end

    assert_equal(2, error.line)
    assert_includes(error.message, "components/DataTable.haml:2: Haml parse error")
    assert_includes(error.message, "> 2 |   = @columns.map { |column| )")
  end

  def test_haml_transformer_compiles_ruby_filter_to_source_fragment
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    parsed = SyntaxTree::Haml.parse(<<~HAML)
      :ruby
        def title
          "Hello"
        end
    HAML
    fragment = transformer.send(:compile_ruby_filter, parsed.children.fetch(0), builder: builder)

    assert_kind_of(Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder::Fragment, fragment)
    assert_nil(fragment.node)
    assert_includes(fragment.source, "SourceMapMark:2")
    assert_includes(fragment.source, "def title")
  end
end
