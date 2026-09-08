# frozen_string_literal: true

require_relative "test_support"

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

  def test_haml_transformer_passes_component_children_eagerly_by_default
    result = transform_component_children

    assert_includes(result.code, "FakeFramework::H[Card, begin")
    assert_includes(result.code, "FakeFramework::H[:p, \"Body\", **HamlHelper.merge_props")
    refute_includes(result.code, "FakeFramework::H[Card] do")
  end

  def test_haml_transformer_can_pass_component_children_lazily
    result = transform_component_children(component_children: :lazy)

    assert_includes(result.code, "FakeFramework::H[Card, **HamlHelper.merge_props(self.class, {})] do")
    assert_includes(result.code, "[begin")
    assert_includes(result.code, "FakeFramework::H[:p, \"Body\", **HamlHelper.merge_props")
  end

  def test_haml_transformer_scopes_component_tag_names
    result =
      Klenod::Build::Plugins::HamlPlugin::Transformer.new.call(
        source: "%Card\n%Foo::Bar\n",
        module_id: ModuleId.new("pages/page.haml", nil),
        component_class_name: "Page",
        component_base_class: "Object",
        factory: "FakeFramework::H",
        styles_source: "{}.freeze",
        translations_source: "{}.freeze",
        styleable: true
      )

    assert_includes(result.code, ":__Card")
    assert_includes(result.code, ":__Foo_Bar")
  end

  def test_haml_transformer_returns_nested_haml_from_early_returns
    result =
      Klenod::Build::Plugins::HamlPlugin::Transformer.new.call(
        source: <<~HAML,
          - if first
            - return
              %p First
          - return if second
            %p Second
          - return unless third
            %p Third
          %p Last
        HAML
        module_id: ModuleId.new("pages/page.haml", nil),
        component_class_name: "Page",
        component_base_class: "Object",
        factory: "FakeFramework::H",
        styles_source: "{}.freeze",
        translations_source: "{}.freeze"
      )

    assert_equal(3, result.code.scan("return begin").length)
    assert_match(/return begin\n\s+# SourceMapMark:\d+\n\s+FakeFramework::H\[:p, "First", \*\*HamlHelper\.merge_props/, result.code)
    assert_match(/return begin\n\s+# SourceMapMark:\d+\n\s+FakeFramework::H\[:p, "Second", \*\*HamlHelper\.merge_props/, result.code)
    assert_match(/return begin\n\s+# SourceMapMark:\d+\n\s+FakeFramework::H\[:p, "Third", \*\*HamlHelper\.merge_props/, result.code)
    assert_includes(result.code, "FakeFramework::H[:p, \"Last\", **HamlHelper.merge_props")
  end

  def test_haml_transformer_can_compile_event_handler_references
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
    result =
      transformer.call(
        source: "%button(onclick=handle_click) Click\n",
        module_id: ModuleId.new("pages/page.haml", nil),
        component_class_name: "Page",
        component_base_class: "Object",
        factory: "#{self.class.name}::FakeFramework::H",
        event_handler: "#{self.class.name}::FakeFramework::H",
        styles_source: "{}.freeze",
        translations_source: "{}.freeze"
      )

    assert_includes(result.code, "FakeFramework::H.callback(self, :handle_click)")
  end

  def test_haml_transformer_combines_parenthesized_and_brace_attributes_for_event_handlers
    result =
      Klenod::Build::Plugins::HamlPlugin::Transformer.new.call(
        source: "%button(onclick=handle_click){ style: { color: \"red\" } } Click\n",
        module_id: ModuleId.new("pages/page.haml", nil),
        component_class_name: "Page",
        component_base_class: "Object",
        factory: "FakeFramework::H",
        event_handler: "#{self.class.name}::FakeFramework::H",
        styles_source: "{}.freeze",
        translations_source: "{}.freeze"
      )

    assert_includes(result.code, "FakeFramework::H.callback(self, :handle_click)")
    assert_match(/style: begin.*\{ color: "red" \}/m, result.code)
  end

  def test_haml_transformer_preserves_non_bare_event_handler_values
    result =
      Klenod::Build::Plugins::HamlPlugin::Transformer.new.call(
        source: "%button{ onclick: handle_click, oninput: :submit, onload: \"console.log(1)\" } Click\n",
        module_id: ModuleId.new("pages/page.haml", nil),
        component_class_name: "Page",
        component_base_class: "Object",
        factory: "FakeFramework::H",
        event_handler: "#{self.class.name}::FakeFramework::H",
        styles_source: "{}.freeze",
        translations_source: "{}.freeze"
      )

    assert_includes(result.code, "FakeFramework::H.callback(self, :handle_click)")
    refute_includes(result.code, "callback(self, :submit)")
    assert_includes(result.code, ":submit")
    assert_includes(result.code, '"console.log(1)"')
  end

  def test_haml_transformer_compiles_component_on_props_as_event_handlers
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
    result =
      transformer.call(
        source: "%GameGrid(ondraw=handle_draw)\n",
        module_id: ModuleId.new("pages/page.haml", nil),
        component_class_name: "Page",
        component_base_class: "Object",
        factory: "#{self.class.name}::FakeFramework::H",
        event_handler: "#{self.class.name}::FakeFramework::H",
        styles_source: "{}.freeze",
        translations_source: "{}.freeze"
      )

    assert_includes(result.code, "callback(self, :handle_draw)")
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

  def test_haml_transformer_does_not_insert_source_marks_inside_ruby_filter_heredocs
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    parsed = SyntaxTree::Haml.parse(<<~HAML)
      :ruby
        ExampleSource = <<~TEXT
          :ruby
            import("./IntlTime.js")

          %time(is="intl-time")
        TEXT
    HAML
    fragment = transformer.send(:compile_ruby_filter, parsed.children.fetch(0), builder: builder)

    assert_includes(fragment.source, "SourceMapMark:2")
    assert_includes(fragment.source, "ExampleSource = <<~TEXT")
    assert_includes(fragment.source, "  :ruby")
    refute_includes(fragment.source, "SourceMapMark:3")
    refute_includes(fragment.source, "SourceMapMark:4")
    refute_includes(fragment.source, "SourceMapMark:5")
    refute_includes(fragment.source, "SourceMapMark:6")
    refute_includes(fragment.source, "SourceMapMark:7")
  end

  private

  def transform_component_children(component_children: :eager)
    Klenod::Build::Plugins::HamlPlugin::Transformer.new.call(
      source: "%Card\n  %p Body\n",
      module_id: ModuleId.new("pages/page.haml", nil),
      component_class_name: "Page",
      component_base_class: "Object",
      factory: "FakeFramework::H",
      component_children: component_children,
      styles_source: "{}.freeze",
      translations_source: "{}.freeze"
    )
  end
end
