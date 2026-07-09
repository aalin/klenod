# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../../backtrace_rewriter"
require_relative "../context"

class Klenod::Build::Plugins::HamlPlugin::Test < Minitest::Test
  ModuleId = Klenod::Build::ModuleId

  module FakeFramework
    class ComponentBase
    end

    module H
      def self.[](tag, *children, **props)
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
        {custom: true}
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
    assert_includes(fragment.source, '**{:class => "intro"}')
  end

  def test_ruby_builder_fragments_keep_parsed_syntax_tree_nodes
    builder = Klenod::Build::Plugins::HamlPlugin::DefaultTransformer::RubyBuilder.new
    unmarked = builder.expression('H[:p, **{:class => "intro"}]')

    assert_kind_of(SyntaxTree::ARef, unmarked.node)
    assert_equal('H[:p, **{ class: "intro" }]', unmarked.source)
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

  def test_haml_records_companion_watched_patterns
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("pages/page.haml")

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
      record = context.load("pages/hello-world.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_operator(exports::Default, :<, FakeFramework::ComponentBase)
      assert_equal([:h1, "Hello"], exports::Default.new.render)
      assert_equal(exports::Default::Styles, exports::Styles)
      assert_equal(exports::Default::Translations, exports::Translations)
    end
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
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.load("pages/page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:main, [:h1, "Hello"], [:p, "From Ruby"], {class: "SHELL"}], exports::Default.new.render)
      assert_kind_of(Klenod::SourceMap::SourceMap, record.source_map)
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
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.load("pages/handlers.haml")
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
      record = context.load("pages/list.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:ul, [[:li, "A"], [:li, "B"]]], exports::Default.new.render)
      assert_match(/SourceMapMark:8:/, record.transformed_source)
      assert_match(/SourceMapMark:9:/, record.transformed_source)
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
      record = context.load("pages/conditional.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:p, "Visible"], exports::Default.new(show: true).render)
      assert_equal([:p, "Empty"], exports::Default.new(show: false).render)
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
      record = context.load("pages/conditional.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([:section, [:p, "Visible"]], exports::Default.new(show: true).render)
      assert_equal([:section, [:p, "Empty"]], exports::Default.new(show: false).render)
      assert_match(/SourceMapMark:8:/, record.transformed_source)
      assert_match(/SourceMapMark:10:/, record.transformed_source)
    end
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
      record = context.load("page.haml")
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
      record = context.load("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\Apages\/page\.haml:3:in /, error.backtrace.fetch(0))
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
      record = context.load("pages/custom.haml")
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
      record = context.load("pages/page.haml")
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

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.load("pages/page.haml")

      assert_equal({}, context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles)

      File.write(css_path, ".title { color: red; }\n")
      result = context.invalidate_paths([css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_match(/title/, styles.fetch("title"))
      assert(context.graph.records.key?(ModuleId.new("pages/page.css", nil)))
    end
  end

  def test_editing_companion_intl_reloads_haml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.load("pages/page.haml")

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
      haml_record = context.load("pages/page.haml")
      old_asset_path = context.graph.records.fetch(ModuleId.new("pages/page.css", nil)).assets.first.output_path
      old_styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      File.write(css_path, ".heading { color: blue; }\n")
      result = context.invalidate_paths([css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      css_record = context.graph.records.fetch(ModuleId.new("pages/page.css", nil))

      assert_equal(["pages/page.css", "pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_match(/title/, old_styles.fetch("title"))
      refute_includes(styles.keys, "title")
      assert_match(/heading/, styles.fetch("heading"))
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
      haml_record = context.load("pages/page.haml")

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
      haml_record = context.load("pages/page.haml")

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
      context.load("pages/page.haml")

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
      haml_record = context.load("pages/page.haml")

      assert_match(/title/, context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles.fetch("title"))

      File.delete(css_path)
      result = context.invalidate_paths([], removed_paths: [css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(["pages/page.css"], result.removed_module_ids.map(&:to_s))
      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_equal({}, styles)
    end
  end
end
