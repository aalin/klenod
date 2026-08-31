# frozen_string_literal: true

module Example
  module H
    Element = Data.define(:tag, :key, :slot, :props, :children)
    Text = Data.define(:value)
    Comment = Data.define(:value)
    Fragment = Data.define(:key, :slot, :children)

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

    def self.[](tag, *children, **props)
      tag = tag.fetch(:tag) if custom_element_descriptor?(tag)
      return render_component(tag, **props, children: children) if tag.is_a?(Class)

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

    def self.render(value)
      HTMLRenderer.render(value)
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
      when Element, Text, Comment, Fragment, Children
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

      path, suffix = href.to_s.match(/\A([^?#]*)(.*)\z/).captures
      routes = Context.current&.routes
      return props unless routes

      locale = props[:hreflang] || Context.current&.request&.locale
      props[:href] = "#{routes.localized_href(path, locale: locale)}#{suffix}"
      props
    end

    def self.localizable_href?(href)
      value = href.to_s
      return false unless value.start_with?("/")
      return false if value.start_with?("//")
      return false if value == "/assets" || value.start_with?("/assets/")

      true
    end

    def self.render_component(tag, **props)
      child_slots = partition_slots(props.delete(:children) || [])
      slots = merge_slots(props.delete(:slots), child_slots)
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

    def self.merge_slots(existing_slots, child_slots)
      slots = {}
      (existing_slots || {}).each { |name, children| slots[name] = normalize_children(children) }
      child_slots.each { |name, children| slots[name] = [*slots[name], *children] }
      slots
    end
  end
end
