# frozen_string_literal: true

require_relative "../haml_plugin_test_support"

class Klenod::Build::Plugins::HamlPlugin::TransformerTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_transform_result_can_be_built_from_ast
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    ast = builder.program("class Page\nend\n")
    result =
      Klenod::Build::Plugins::HamlPlugin::HamlTransformResult.from_ast(
        ast,
        source: "%h1 Hello\n",
        metadata: {custom: true}
      )

    assert_equal(ast.source, result.code)
    assert_same(ast, result.ast)
    assert_kind_of(Klenod::Runtime::SourceMap::SourceMap, result.source_map)
    assert_equal({custom: true}, result.metadata)
  end

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
    assert_kind_of(SyntaxTree::Node, template.render.node)
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
    assert_kind_of(Haml::SyntaxError, error.cause)
  end

  def test_haml_transformer_wraps_invalid_tag_parse_errors_with_source_context
    transformer = Klenod::Build::Plugins::HamlPlugin::Transformer.new
    source = <<~HAML
      %p Before
      %*
      %p After
    HAML
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        transformer.call(
          source: source,
          module_id: ModuleId.new("pages/demo/blog/[slug]/page.haml", nil),
          component_class_name: "Page",
          component_base_class: "Object",
          factory: "#{self.class.name}::FakeFramework::H",
          styles_source: "{}.freeze",
          translations_source: "{}.freeze"
        )
      end

    assert_equal(ModuleId.new("pages/demo/blog/[slug]/page.haml", nil), error.module_id)
    assert_equal(2, error.line)
    assert_includes(error.message, "pages/demo/blog/[slug]/page.haml:2: Haml parse error")
    assert_includes(error.message, "Invalid tag")
    assert_includes(error.message, "> 2 | %*")
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

  def test_haml_plugin_wraps_inline_css_parse_errors_with_source_context
    plugin = Klenod::Build::Plugins::HamlPlugin.new
    module_id = ModuleId.new("pages/page.haml", nil)
    source = <<~HAML
      %h1 Hello
      %time(datetime=post.fetch("date"))= post.fetch("date")
    HAML
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        plugin.send(:inline_css_sources, source, module_id: module_id)
      end

    assert_equal(2, error.line)
    assert_includes(error.message, "pages/page.haml:2: Haml parse error")
    assert_includes(error.message, "> 2 | %time(datetime=post.fetch(\"date\"))= post.fetch(\"date\")")
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

    Klenod::Build::Plugins::HamlPlugin::Transformer
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

  def haml_plugin(**options)
    Klenod::Build::Plugins::HamlPlugin.new(
      factory: "#{self.class.name}::FakeFramework::H", **options
    )
  end

  def with_files(files)
    Dir.mktmpdir do |dir|
      files.each do |path, source|
        full_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, source)
      end

      yield dir
    end
  end

  def with_haml_context(files, plugin: nil, plugins: nil)
    plugin ||= haml_plugin

    with_files(files) do |dir|
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: plugins || default_plugins_with(plugin)
        )

      yield dir, context, plugin
    end
  end

  def evaluate_haml(files, entry: "pages/page.haml", plugin: nil, plugins: nil)
    plugin ||= haml_plugin

    with_haml_context(files, plugin: plugin, plugins: plugins) do |dir, context|
      record = context.evaluate(entry)
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      yield dir, context, record, exports
    end
  end

  def test_haml_transformer_compiles_ruby_filter_to_statement_fragment
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
    assert_kind_of(SyntaxTree::Statements, fragment.node)
    assert_kind_of(SyntaxTree::Comment, fragment.node.body.first)
    assert_includes(builder.fragment(fragment.node).source, "SourceMapMark:2")
  end
end
