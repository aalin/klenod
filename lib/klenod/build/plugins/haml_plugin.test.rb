# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"

class Klenod::Build::Plugins::HamlPlugin::Test < Minitest::Test
  ModuleId = Klenod::Build::ModuleId

  module FakeFramework
    class ComponentBase
    end

    DescriptorFactory = Object.new
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
            DescriptorFactory = #{kwargs.fetch(:descriptor_factory)}
            Translations = #{kwargs.fetch(:translations_source)}

            def render
              [:custom, DescriptorFactory]
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
          descriptor_factory: "#{self.class.name}::FakeFramework::DescriptorFactory"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.load("pages/hello-world.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_operator(exports::Default, :<, FakeFramework::ComponentBase)
      assert_same(FakeFramework::DescriptorFactory, exports::Default.new.render)
      assert_equal(exports::Default::Styles, exports::Styles)
      assert_equal(exports::Default::Translations, exports::Translations)
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
          descriptor_factory: "#{self.class.name}::FakeFramework::DescriptorFactory",
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
      assert_equal("#{self.class.name}::FakeFramework::DescriptorFactory", call.fetch(:descriptor_factory))
      assert_equal("{}.freeze", call.fetch(:styles_source))
      assert_equal("{}.freeze", call.fetch(:translations_source))
      assert_equal([:custom, FakeFramework::DescriptorFactory], exports::Default.new.render)
      assert_equal(:source_map, record.source_map)
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

      File.write(css_path, ".title { color: blue; }\n")
      result = context.invalidate_paths([css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      css_record = context.graph.records.fetch(ModuleId.new("pages/page.css", nil))

      assert_equal(["pages/page.css", "pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_match(/title/, styles.fetch("title"))
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
