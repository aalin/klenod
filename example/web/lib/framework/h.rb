# frozen_string_literal: true

module Example
  module Framework
    module H
      Element = Data.define(:tag, :key, :slot, :props, :children)
      Text = Data.define(:value)
      Comment = Data.define(:value)
      Fragment = Data.define(:key, :slot, :children)

      class ContextBoundary
        attr_reader :values

        def initialize(values, &producer)
          @values = values.freeze
          @producer = producer
        end

        def children
          return @children if defined?(@children)

          @children = H.normalize_child(@producer.call).freeze
        end
      end

      class Slots
        def initialize(explicit = nil, children: nil, &producer)
          @explicit = (explicit || {}).to_h { |name, value| [name&.to_sym, value] }
          @children = children
          @producer = producer
          @resolved_explicit = {}
        end

        def fetch(name, default = nil)
          key = name&.to_sym
          values = [*explicit_children(key), *produced_slots.fetch(key, [])]
          return values unless values.empty?

          default
        end

        def [](name)
          fetch(name)
        end

        private

        def explicit_children(name)
          return [] unless @explicit.key?(name)
          return @resolved_explicit.fetch(name) if @resolved_explicit.key?(name)

          value = @explicit.fetch(name)
          value = value.call if value.respond_to?(:call)
          @resolved_explicit[name] = H.normalize_child(value).freeze
        end

        def produced_slots
          return @produced_slots if defined?(@produced_slots)

          children = [*@children]
          children.concat(H.normalize_child(@producer.call)) if @producer
          @produced_slots = H.partition_slots(children).transform_values(&:freeze).freeze
        end
      end

      class Children
        include Enumerable

        attr_reader :slots

        def initialize(slots, name = nil)
          @slots = slots
          @slots = Slots.new(@slots) unless @slots.is_a?(Slots)
          @name = name
        end

        def [](name)
          self.class.new(@slots, name&.to_sym)
        end

        def each(&)
          nodes.each(&)
        end

        def empty?
          nodes.empty?
        end

        def any?(...)
          nodes.any?(...)
        end

        def length
          nodes.length
        end
        alias_method :size, :length

        def to_a
          nodes
        end

        def text_content
          H.text_content(nodes)
        end

        private

        def nodes
          @slots.fetch(@name, [])
        end
      end

      def self.[](tag, *children, **props, &lazy_children)
        tag = tag.fetch(:tag) if custom_element_descriptor?(tag)
        return render_component(tag, *children, **props, &lazy_children) if tag.is_a?(Class)

        children.concat(normalize_child(lazy_children.call)) if lazy_children

        key = props.delete(:key)
        slot = props.delete(:slot)&.to_sym

        Element[tag, key, slot, props, normalize_children(children)]
      end

      def self.custom_element_descriptor?(tag)
        tag.is_a?(Hash) && tag[:__klenod_custom_element] == true && tag.key?(:tag)
      end

      def self.fragment(*children, key: nil, slot: nil)
        Fragment[key, slot&.to_sym, normalize_children(children)]
      end

      def self.context(**values, &producer)
        ContextBoundary.new(values, &producer)
      end

      def self.render(value, **options)
        HTMLRenderer.render(value, **options)
      end

      def self.render_document(value, **options)
        HTMLRenderer.render_document(value, **options)
      end

      def self.text_content(value)
        output = +""
        append_text_content(output, value)
        output
      end

      def self.normalize_children(children)
        children.flat_map { |child| normalize_child(child) }
      end

      def self.normalize_child(child)
        case child
        when nil, false
          []
        when Element, Text, Comment, Fragment, ContextBoundary, Children
          [child]
        when Array
          normalize_children(child)
        else
          [Text[child]]
        end
      end

      def self.append_text_content(output, value)
        case value
        when nil, false
          nil
        when Element, Fragment
          value.children.each { |child| append_text_content(output, child) }
        when ContextBoundary
          Context.with(**value.values) do
            value.children.each { |child| append_text_content(output, child) }
          end
        when Text
          output << value.value.to_s
        when Comment
          nil
        when Children
          value.each { |child| append_text_content(output, child) }
        when Array
          value.each { |child| append_text_content(output, child) }
        else
          output << value.to_s
        end
      end

      def self.localize_anchor_props(props)
        href = props[:href]
        return props unless localizable_href?(href)

        props[:href] = localize_href(href, locale: props[:hreflang])
        props
      end

      def self.localize_href(href, locale: nil)
        return href unless localizable_href?(href)

        path, suffix = href.to_s.match(/\A([^?#]*)(.*)\z/).captures
        routes = Context.current&.routes
        return href unless routes

        locale ||= Context.current&.request&.locale
        "#{routes.localized_href(path, locale: locale)}#{suffix}"
      end

      def self.localizable_href?(href)
        value = href.to_s
        return false unless value.start_with?("/")
        return false if value.start_with?("//")
        return false if value == "/assets" || value.start_with?("/assets/")

        true
      end

      def self.render_component(tag, *children, **props, &producer)
        slots = Slots.new(props.delete(:slots), children: children, &producer)
        children = Children.new(slots)

        if tag.respond_to?(:instantiate)
          tag.instantiate(**props, children: children, slots: slots).render
        else
          tag.new(**props, children: children).render
        end
      end

      def self.partition_slots(children)
        normalize_children(children).each_with_object({}) do |child, slots|
          slot = child.respond_to?(:slot) ? child.slot : nil
          slots[slot] ||= []
          slots[slot] << without_slot(child)
        end
      end

      def self.without_slot(child)
        case child
        when Element, Fragment
          child.with(slot: nil)
        else
          child
        end
      end
    end
  end
end
