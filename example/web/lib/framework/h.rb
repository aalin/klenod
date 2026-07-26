# frozen_string_literal: true

require "cgi/escape"

module Example
  module H
    Element = Data.define(:tag, :key, :slot, :props, :children)
    Text = Data.define(:value)
    Comment = Data.define(:value)
    Fragment = Data.define(:key, :slot, :children)

    VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].to_set.freeze
    HTML_ESCAPE_PATTERN = /[&"<>]/

    def self.[](tag, *children, **props)
      return render_component(tag, **props, children: children) if tag.is_a?(Class)

      key = props.delete(:key)
      slot = props.delete(:slot)&.to_sym

      Element[tag, key, slot, props, normalize_children(children)]
    end

    def self.fragment(*children, key: nil, slot: nil)
      Fragment[key, slot&.to_sym, normalize_children(children)]
    end

    def self.render(value)
      output = +""
      append_rendered(output, value)
      output
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
      when Element, Text, Comment, Fragment
        [child]
      when Array
        normalize_children(child)
      else
        [Text[child]]
      end
    end

    def self.escape_html(value)
      string = value.to_s
      return string unless string.match?(HTML_ESCAPE_PATTERN)

      CGI.escapeHTML(string)
    end

    def self.append_rendered(output, value)
      case value
      when nil, false
        nil
      when Element
        append_element(output, value)
      when Text
        output << escape_html(value.value)
      when Comment
        output << "<!--"
        output << value.value.to_s.gsub("--", "- -")
        output << "-->"
      when Fragment
        value.children.each { |child| append_rendered(output, child) }
      when Array
        value.each { |child| append_rendered(output, child) }
      else
        output << escape_html(value)
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
      when Array
        value.each { |child| append_text_content(output, child) }
      else
        output << value.to_s
      end
    end

    def self.append_element(output, element)
      props = element.props
      props = localize_anchor_props(props.dup) if element.tag == :a
      rendered_attributes = rendered_attributes(props)

      output << "<#{element.tag}#{rendered_attributes}>"
      return if VOID_TAGS.include?(element.tag)

      element.children.each { |child| append_rendered(output, child) }
      output << "</#{element.tag}>"
    end

    def self.rendered_attributes(props)
      return "" if props.empty?

      output = +""
      props.each do |name, value|
        next if value.nil? || value == false

        output << " "
        output << (name.is_a?(Symbol) ? name.to_s : escape_html(name))
        next if value == true

        output << '="'
        output << escape_html(value)
        output << '"'
      end
      output
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
      props = props.merge(children: slots.fetch(nil, []), slots: slots)

      if tag.respond_to?(:instantiate)
        tag.instantiate(**props).render
      else
        tag.new(**props).render
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
