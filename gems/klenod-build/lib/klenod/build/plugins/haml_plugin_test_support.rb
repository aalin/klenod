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
      def self.instantiate(**props)
        instance = allocate
        instance.instance_variable_set(:@__props, props.freeze)

        if instance.method(:initialize).parameters.empty?
          instance.send(:initialize)
        else
          instance.send(:initialize, **props)
        end

        instance
      end

      def initialize(**props)
        @__props = props.freeze
      end
    end

    module HamlHelper
      def self.merge_props(component_class, *sources)
        result =
          sources.compact.reduce({}) do |props, source|
            props.merge(source) do |key, old_value, new_value|
              (key == :class) ? [old_value, new_value].flatten : new_value
            end
          end

        if result.key?(:class)
          classes = Array(result.delete(:class)).compact
          styles = component_class.const_defined?(:Styles, false) ? component_class::Styles : {}
          class_names =
            classes.map do |class_name|
              if class_name.is_a?(Symbol)
                name = class_name.to_s
                styles[class_name] || (name.start_with?("__") ? nil : name)
              else
                class_name
              end
            end.compact
          result[:class] = Klenod::Runtime.class_names(class_names) unless class_names.empty?
        end

        result.transform_keys { it.to_s.tr("-", "_").to_sym }
      end
    end

    module H
      def self.[](tag, *children, **props)
        props = props.compact

        return tag.instantiate(**props, children: children).render if tag.respond_to?(:instantiate)
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
    styleable = basename == "style_classes"

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
        styleable: styleable,
        haml_helper_source: ("HamlHelper = #{self.class.name}::FakeFramework::HamlHelper" if styleable)
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
      component_base_class: "#{self.class.name}::FakeFramework::ComponentBase",
      factory: "#{self.class.name}::FakeFramework::H",
      **options
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
