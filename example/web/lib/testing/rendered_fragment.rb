# frozen_string_literal: true

require "nokolexbor"

module Example
  module Testing
    class QueryError < StandardError
    end

    class StaticAccessibility
      TEXTBOX_INPUT_TYPES = %w[email password search tel text url].freeze
      BUTTON_INPUT_TYPES = %w[button image reset submit].freeze
      LABELABLE_TAGS = %w[button input meter output progress select textarea].freeze

      def initialize(fragment)
        @fragment = fragment
        @nodes_by_id = fragment.css("[id]").to_h { [it["id"], it] }
      end

      def role(node)
        explicit = node["role"].to_s.split.first
        return explicit unless explicit.to_s.empty?

        native_role(node)
      end

      def name(node, seen = Set.new)
        added = seen.add?(node.object_id)
        return "" unless added

        aria_label = node["aria-label"]
        return normalize(aria_label) unless aria_label.nil?

        labelled_by = node["aria-labelledby"].to_s.split.filter_map do |id|
          reference = nodes_by_id[id]
          name(reference, seen) if reference
        end
        return normalize(labelled_by.join(" ")) unless labelled_by.empty?

        labels = labels_for(node).map { visible_text(it) }
        return normalize(labels.join(" ")) unless labels.empty?

        return normalize(node["alt"]) if node.name == "img" || input_type(node) == "image"
        if node.name == "input" && BUTTON_INPUT_TYPES.include?(input_type(node))
          return normalize(node["value"] || input_type(node).capitalize)
        end

        visible_text(node)
      ensure
        seen.delete(node.object_id) if added
      end

      def hidden?(node)
        current = node
        while current&.element?
          return true if current.attributes.key?("hidden")
          return true if current["aria-hidden"].to_s.casecmp?("true")
          return true if current.name == "input" && input_type(current) == "hidden"

          current = current.parent
        end
        false
      end

      def visible_text(node)
        text = node.children.filter_map do |child|
          if child.text?
            child.text
          elsif child.element? && !hidden?(child) && !%w[script style template].include?(child.name)
            visible_text(child)
          end
        end
        normalize(text.join(" "))
      end

      def normalize(value)
        value.to_s.gsub(/\s+/, " ").strip
      end

      private

      attr_reader :fragment, :nodes_by_id

      def native_role(node)
        case node.name
        when "a", "area"
          "link" if node.attributes.key?("href")
        when "button", "summary"
          "button"
        when "h1", "h2", "h3", "h4", "h5", "h6"
          "heading"
        when "ul", "ol", "menu"
          "list"
        when "li"
          "listitem"
        when "input"
          input_role(node)
        when "textarea"
          "textbox"
        when "select"
          (node.attributes.key?("multiple") || node["size"].to_i > 1) ? "listbox" : "combobox"
        when "option"
          "option"
        when "img"
          "img" unless node["alt"] == ""
        when "progress"
          "progressbar"
        when "meter"
          "meter"
        when "output"
          "status"
        when "nav"
          "navigation"
        when "main"
          "main"
        when "aside"
          "complementary"
        when "dialog"
          "dialog"
        when "table"
          "table"
        when "tr"
          "row"
        when "th"
          (node["scope"] == "row") ? "rowheader" : "columnheader"
        when "td"
          "cell"
        end
      end

      def input_role(node)
        type = input_type(node)
        return "button" if BUTTON_INPUT_TYPES.include?(type)
        return "checkbox" if type == "checkbox"
        return "radio" if type == "radio"
        return "slider" if type == "range"
        return "spinbutton" if type == "number"
        return "searchbox" if type == "search"
        return "textbox" if TEXTBOX_INPUT_TYPES.include?(type)

        nil
      end

      def input_type(node)
        (node.name == "input") ? (node["type"] || "text").downcase : nil
      end

      def labels_for(node)
        return [] unless LABELABLE_TAGS.include?(node.name)

        labels = []
        id = node["id"]
        labels.concat(fragment.css("label").select { it["for"] == id && !hidden?(it) }) unless id.to_s.empty?
        wrapping = node.ancestors.find { it.element? && it.name == "label" && !hidden?(it) }
        labels << wrapping if wrapping
        labels.uniq
      end
    end

    class QueryScope
      def initialize(container, fragment:, html:, accessibility:)
        @container = container
        @fragment = fragment
        @html = html
        @accessibility = accessibility
      end

      attr_reader :fragment, :html

      def get_by_role(role, name: nil)
        role_query(:get_by_role, role, name: name)
      end

      def query_by_role(role, name: nil)
        role_query(:query_by_role, role, name: name)
      end

      def get_all_by_role(role, name: nil)
        role_query(:get_all_by_role, role, name: name)
      end

      def query_all_by_role(role, name: nil)
        role_query(:query_all_by_role, role, name: name)
      end

      def get_by_text(matcher)
        text_query(:get_by_text, matcher)
      end

      def query_by_text(matcher)
        text_query(:query_by_text, matcher)
      end

      def get_all_by_text(matcher)
        text_query(:get_all_by_text, matcher)
      end

      def query_all_by_text(matcher)
        text_query(:query_all_by_text, matcher)
      end

      def get_by_css(selector)
        css_query(:get_by_css, selector)
      end

      def query_by_css(selector)
        css_query(:query_by_css, selector)
      end

      def get_all_by_css(selector)
        css_query(:get_all_by_css, selector)
      end

      def query_all_by_css(selector)
        css_query(:query_all_by_css, selector)
      end

      def has_role?(role, name: nil)
        !query_all_by_role(role, name: name).empty?
      end

      def has_text?(matcher)
        !query_all_by_text(matcher).empty?
      end

      def has_css?(selector)
        !query_all_by_css(selector).empty?
      end

      def within(node)
        unless node.is_a?(Nokolexbor::Node) && fragment.css("*").include?(node)
          raise ArgumentError, "within expects a node from this rendered fragment"
        end

        QueryScope.new(node, fragment: fragment, html: html, accessibility: accessibility)
      end

      private

      attr_reader :container, :accessibility

      def role_query(method_name, role, name: nil)
        role = role.to_s
        candidates = elements.select { !accessibility.hidden?(it) && accessibility.role(it) == role }
        matches = name ? candidates.select { text_matches?(accessibility.name(it), name) } : candidates
        resolve(method_name, [role.to_sym, {name: name}], matches, candidates: name ? candidates : matches) do |node|
          %(role=#{role.inspect}, name=#{accessibility.name(node).inspect}, #{node.to_html})
        end
      end

      def text_query(method_name, matcher)
        candidates = elements.reject { accessibility.hidden?(it) || %w[script style template].include?(it.name) }
        matches = candidates.select { text_matches?(accessibility.visible_text(it), matcher) }
        matches.reject! do |node|
          node.css("*").any? do |descendant|
            !accessibility.hidden?(descendant) && text_matches?(accessibility.visible_text(descendant), matcher)
          end
        end
        resolve(method_name, [matcher], matches)
      end

      def css_query(method_name, selector)
        resolve(method_name, [selector], container.css(selector).to_a)
      end

      def elements
        container.css("*").to_a
      end

      def text_matches?(actual, matcher)
        case matcher
        when String
          actual == accessibility.normalize(matcher)
        when Regexp
          matcher.match?(actual)
        else
          raise ArgumentError, "text matcher must be a String or Regexp"
        end
      end

      def resolve(method_name, arguments, matches, candidates: matches, &describe_candidate)
        return matches if method_name.to_s.start_with?("query_all")
        if method_name.to_s.start_with?("get_all")
          return matches unless matches.empty?
        end
        return matches.first if matches.length == 1
        return nil if matches.empty? && method_name.to_s.start_with?("query_by")

        expectation = method_name.to_s.start_with?("get_all") ? "one or more" : "exactly one"
        reason = matches.empty? ? "No matches found" : "Found #{matches.length} matches"
        query = format_query(method_name, arguments)
        candidate_nodes = matches.empty? ? candidates : matches
        raise QueryError, diagnostic(query, reason, expectation, candidate_nodes, &describe_candidate)
      end

      def format_query(method_name, arguments)
        values = arguments.flat_map do |argument|
          if argument.is_a?(Hash)
            argument.filter_map { |key, value| "#{key}: #{value.inspect}" unless value.nil? }
          else
            argument.inspect
          end
        end
        "#{method_name}(#{values.join(", ")})"
      end

      def diagnostic(query, reason, expectation, candidates)
        lines = ["Query: #{query}", "#{reason}; expected #{expectation}."]
        unless candidates.empty?
          lines << "" << "Candidates:"
          candidates.each_with_index do |node, index|
            description = block_given? ? yield(node) : node.to_html
            lines << "  #{index + 1}. #{description}"
          end
        end
        lines << "" << "Rendered HTML:" << indent(fragment.to_html(indent: 2).rstrip, "  ")
        lines.join("\n")
      end

      def indent(value, prefix)
        value.lines.map { "#{prefix}#{it}" }.join.rstrip
      end
    end

    class RenderedFragment < QueryScope
      def initialize(html)
        fragment = Nokolexbor::DocumentFragment.parse(html)
        super(fragment, fragment: fragment, html: html.freeze, accessibility: StaticAccessibility.new(fragment))
      end
    end
  end
end
