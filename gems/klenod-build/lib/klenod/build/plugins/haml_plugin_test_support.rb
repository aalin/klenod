# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "klenod/runtime"
require_relative "../context"

class Klenod::Build::Plugins::HamlPlugin::TestSupport < Minitest::Test
  ModuleId = Klenod::Build::ModuleId
  TEST_FIXTURE_DIR = File.expand_path("__test__", __dir__)
  HAML_FIXTURE_DIR = File.join(TEST_FIXTURE_DIR, "haml")

  module FakeFramework
    class ComponentBase
      def initialize(**props)
        @__props = props.freeze
      end
    end

    module H
      def self.[](tag, *children, **props)
        props = props.compact

        return tag.new(**props, children: children).render if tag.is_a?(Class)

        props.empty? ? [tag, *children] : [tag, *children, props]
      end
    end
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
      .then { |result| format_generated_ruby(result.code) }
  end

  def format_generated_ruby(source)
    SyntaxTree::Formatter.format(+"", SyntaxTree.parse(source), 0)
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
end
