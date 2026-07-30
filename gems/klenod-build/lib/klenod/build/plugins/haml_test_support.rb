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
    class Children
      include Enumerable

      def initialize(slots, name = nil)
        @slots = slots
        @name = name
      end

      def [](name)
        self.class.new(@slots, name&.to_sym)
      end

      def each(&)
        to_a.each(&)
      end

      def empty?
        to_a.empty?
      end

      def to_a
        @slots.fetch(@name, [])
      end
    end

    class ComponentBase
      attr_reader :__slots

      def self.instantiate(**props)
        slots = props.delete(:slots) || {}
        if (props.key?(:children) || !slots.empty?) && !props[:children].is_a?(Children)
          slots = {nil => Array(props[:children])}.merge(slots) do |_name, existing, added|
            existing + added
          end
          props[:children] = Children.new(slots)
        end

        instance = allocate
        instance.instance_variable_set(:@__props, props.freeze)
        instance.instance_variable_set(:@__slots, slots.freeze)

        parameters = instance.method(:initialize).parameters
        if parameters.empty?
          instance.send(:initialize)
        else
          instance.send(:initialize, **initialize_props(props, parameters))
        end

        instance
      end

      def self.initialize_props(props, parameters)
        props = props.except(:slots)
        return props if parameters.any? { |kind, _name| kind == :keyrest }

        accepted = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
        props.slice(*accepted)
      end

      def initialize(**props)
        @__props = (@__props || {}).merge(props).freeze
        @__slots = (@__slots || {}).freeze
      end

      def children
        @__props[:children]
      end
    end

    module HamlPluginHelper
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

        class_names = component_class.const_defined?(:ClassNames, false) ? component_class::ClassNames : nil
        return nil unless class_names.respond_to?(:class_name)

        class_names.class_name(*classes)
      end

      def self.class_names(*values)
        classes = []
        values.each { |value| collect_output_class_names(classes, value) }
        return nil if classes.empty?

        classes.join(" ")
      end

      def self.render_slot(component, name = nil, fallback = nil)
        children =
          if component.respond_to?(:children)
            name ? component.children[name] : component.children
          elsif component.respond_to?(:__slots)
            component.__slots[name&.to_sym]
          end
        return children if children && !children.empty?

        fallback
      end

      def self.freeze_static(value, seen = {})
        return value if value.nil? || value == true || value == false || value.is_a?(Symbol) || value.is_a?(Numeric)

        object_id = value.object_id
        return value if seen[object_id]

        seen[object_id] = true

        case value
        when String
          nil
        when Array
          value.each { |child| freeze_static(child, seen) }
        when Hash
          value.each do |key, child|
            freeze_static(key, seen)
            freeze_static(child, seen)
          end
        else
          value.deconstruct.each { |child| freeze_static(child, seen) } if value.respond_to?(:deconstruct)
        end

        value.freeze
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
        children = normalize_children(children)

        if tag.respond_to?(:instantiate)
          slots = {nil => children}
          return tag.instantiate(**props, children: Children.new(slots), slots: slots).render
        end
        if tag.is_a?(Class)
          slots = {nil => children}
          parameters = tag.instance_method(:initialize).parameters
          props = ComponentBase.initialize_props(props.merge(children: Children.new(slots)), parameters)
          return tag.new(**props).render
        end

        props.empty? ? [tag, *children] : [tag, *children, props]
      end

      def self.normalize_children(children)
        children.map do |child|
          child.is_a?(Children) ? child.to_a : child
        end
      end
    end
  end

  def transform_haml_fixture(path, cache_static_subtrees: false)
    basename = File.basename(path, ".haml")
    module_id = ModuleId.new("__test__/haml/#{File.basename(path)}", nil)
    class_names_runtime_dependency_id = "virtual:klenod/class_names"
    class_names_runtime = "__klenod_import__(#{class_names_runtime_dependency_id.inspect})"
    styles_source =
      case basename
      when "style_classes"
        "#{class_names_runtime}.new({__figure: \"figure_hash\", __img: \"img_hash\", card: \"card_hash\", image: \"image_hash\"}.freeze)"
      when "inline_css_filter"
        "#{class_names_runtime}.new({title: \"title_hash\"}.freeze)"
      else
        "#{class_names_runtime}.new({}.freeze)"
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
        haml_helper_source: ("HamlHelper = #{self.class.name}::FakeFramework::HamlHelper" if styleable || cache_static_subtrees || fixture_needs_haml_helper?(path)),
        cache_static_subtrees: cache_static_subtrees
      )
      .then { |result| format_generated_ruby(result.code) }
  end

  def fixture_needs_haml_helper?(path)
    queue = Klenod::Build::Plugins::HamlPlugin.parse_haml(File.read(path)).children.dup

    until queue.empty?
      node = queue.shift
      return true if node.type == :tag && !node.value.fetch(:attributes).fetch("class", "").empty?
      return true if node.type == :tag && node.value.fetch(:name) == "slot"

      queue.concat(node.children)
    end

    false
  end

  def format_generated_ruby(source)
    SyntaxTree::Formatter.format(+"", SyntaxTree.parse(source), 0)
  end

  def default_plugins_with(plugin)
    Klenod::Build::Context::DEFAULT_PLUGINS.map do |default_plugin|
      default_plugin.is_a?(Klenod::Build::Plugins::HamlPlugin::Plugin) ? plugin : default_plugin
    end
  end

  def haml_plugin(**options)
    Klenod::Build::Plugins::HamlPlugin::Plugin.new(
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
