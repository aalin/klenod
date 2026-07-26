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
        result = {}
        classes = []

        sources.each do |source|
          next unless source

          source.each do |key, value|
            key = normalize_prop_key(key)
            if key == :class
              collect_class_values(classes, value)
            else
              result[key] = value
            end
          end
        end

        class_name = class_name(component_class, classes)
        result[:class] = class_name if class_name
        result
      end

      def self.normalize_prop_key(key)
        return key if key.is_a?(Symbol) && !key.to_s.include?("-")

        key.to_s.tr("-", "_").to_sym
      end

      def self.collect_class_values(classes, value)
        case value
        when nil, false
          nil
        when Array
          value.each { |item| collect_class_values(classes, item) }
        else
          classes << value
        end
      end

      def self.class_name(component_class, classes)
        return nil if classes.empty?

        styles = component_class.const_defined?(:Styles, false) ? component_class::Styles : {}
        class_names = []
        classes.each do |value|
          if value.is_a?(Symbol)
            name = value.to_s
            collect_output_class_names(class_names, styles[value] || (name.start_with?("__") ? nil : name))
          else
            collect_output_class_names(class_names, value)
          end
        end
        return nil if class_names.empty?

        class_names.join(" ")
      end

      def self.class_names(*values)
        classes = []
        values.each { |value| collect_output_class_names(classes, value) }
        return nil if classes.empty?

        classes.join(" ")
      end

      def self.collect_output_class_names(classes, value)
        case value
        when nil, false
          nil
        when Array
          value.each { |item| collect_output_class_names(classes, item) }
        when Hash
          value.each { |class_name, enabled| collect_output_class_names(classes, class_name) if enabled }
        else
          value.to_s.split.each { |class_name| classes << class_name }
        end
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
    styles_runtime_dependency_id = "virtual:klenod/styles"
    styles_runtime = "__klenod_import__(#{styles_runtime_dependency_id.inspect})"
    styles_source =
      if basename == "style_classes"
        "#{styles_runtime}.new({__figure: \"figure_hash\", __img: \"img_hash\", card: \"card_hash\", image: \"image_hash\"}.freeze)"
      else
        "#{styles_runtime}.new({}.freeze)"
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
        haml_helper_source: ("HamlHelper = #{self.class.name}::FakeFramework::HamlHelper" if styleable || fixture_needs_haml_helper?(path))
      )
      .then { |result| format_generated_ruby(result.code) }
  end

  def fixture_needs_haml_helper?(path)
    queue = Klenod::Build::Plugins::HamlPlugin.parse_haml(File.read(path)).children.dup

    until queue.empty?
      node = queue.shift
      return true if node.type == :tag && !node.value.fetch(:attributes).fetch("class", "").empty?

      queue.concat(node.children)
    end

    false
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
