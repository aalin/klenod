# frozen_string_literal: true

require "cgi/escape"
require "json"
require "uri"

module Example
  Request = Data.define(:method, :path, :params, :query, :headers, :raw) do
    def self.from(raw, params: {})
      raw_path = raw&.path.to_s
      raw_path = "/" if raw_path.empty?
      path, query_string = raw_path.split("?", 2)

      self[
        raw&.method.to_s.empty? ? "GET" : raw.method.to_s.upcase,
        path.empty? ? "/" : path,
        params,
        parse_query(query_string),
        headers_from(raw),
        raw
      ]
    end

    def self.parse_query(query_string)
      return {} if query_string.to_s.empty?

      URI
        .decode_www_form(query_string)
        .each_with_object({}) { |(key, value), query| query[key] = value }
    end

    def self.headers_from(raw)
      headers = raw.headers if raw&.respond_to?(:headers)
      return {} unless headers&.respond_to?(:each)

      result = {}
      headers.each do |header|
        name, value = header
        result[name.to_s.downcase] = value.to_s if name
      end
      result
    end

    def with_params(params)
      self.class[method, path, params, query, headers, raw]
    end
  end

  Response = Data.define(:status, :headers, :body) do
    def self.json(value, status: 200, headers: {})
      self[
        status,
        {"content-type" => "application/json; charset=utf-8"}.merge(headers),
        [JSON.generate(value)]
      ]
    end

    def self.text(value, status: 200, headers: {})
      self[
        status,
        {"content-type" => "text/plain; charset=utf-8"}.merge(headers),
        [value.to_s]
      ]
    end

    def self.html(value, status: 200, headers: {})
      self[
        status,
        {"content-type" => "text/html; charset=utf-8"}.merge(headers),
        [value.to_s]
      ]
    end

    def self.redirect(location, status: 302, headers: {})
      self[status, {"location" => location}.merge(headers), []]
    end

    def to_a
      [status, headers, body]
    end

    def with_header(name, value)
      self.class[status, headers.merge(name.to_s => value.to_s), body]
    end
  end

  class Component
    def initialize(...)
    end
  end

  class Route
  end

  module H
    HtmlString = Class.new(String)
    VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].freeze

    def self.[](tag, *children, **props)
      return tag.new(**props, children: children).render if tag.is_a?(Class)

      rendered_attributes =
        props
          .compact
          .reject { |_name, value| value == false }
          .map { |name, value| rendered_attribute(name, value) }
          .join

      return HtmlString.new("<#{tag}#{rendered_attributes}>") if VOID_TAGS.include?(tag)

      rendered_children = children.flatten.compact.map { |child| escape_html(child) }.join
      HtmlString.new("<#{tag}#{rendered_attributes}>#{rendered_children}</#{tag}>")
    end

    def self.escape_html(value)
      return value.to_s if value.is_a?(HtmlString)

      CGI.escapeHTML(value.to_s)
    end

    def self.rendered_attribute(name, value)
      return " #{escape_html(name)}" if value == true

      %( #{escape_html(name)}="#{escape_html(value)}")
    end
  end
end
