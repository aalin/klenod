# frozen_string_literal: true

require "cgi/escape"
require "json"
require "rbnacl"
require "uri"

module Example
  SESSION_COOKIE = "klenod_example_session"
  SESSION_SECRET = ENV.fetch("KLENOD_EXAMPLE_SESSION_SECRET", "klenod example development session secret")

  Request = Data.define(:method, :path, :params, :query, :headers, :cookies, :form, :session, :raw) do
    def self.from(raw, params: {})
      raw_path = raw&.path.to_s
      raw_path = "/" if raw_path.empty?
      path, query_string = raw_path.split("?", 2)
      headers = headers_from(raw)
      cookies = parse_cookies(headers.fetch("cookie", nil))

      self[
        raw&.method.to_s.empty? ? "GET" : raw.method.to_s.upcase,
        path.empty? ? "/" : path,
        params,
        parse_query(query_string),
        headers,
        cookies,
        parse_form(read_body(raw)),
        SessionCookie.decode(cookies[SESSION_COOKIE]),
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

    def self.parse_cookies(cookie_header)
      return {} if cookie_header.to_s.empty?

      cookie_header
        .split(";")
        .filter_map do |cookie|
          name, value = cookie.strip.split("=", 2)
          [name, URI.decode_www_form_component(value || "")] unless name.to_s.empty?
        end
        .to_h
    end

    def self.read_body(raw)
      body = raw.body if raw&.respond_to?(:body)
      return "" unless body
      return body if body.is_a?(String)
      if body.respond_to?(:read)
        chunks = []
        loop do
          chunk = body.read
          break unless chunk

          chunks << chunk
        end
        return chunks.join
      end

      body.to_s
    end

    def self.parse_form(body)
      return {} if body.to_s.empty?

      URI
        .decode_www_form(body)
        .each_with_object({}) { |(key, value), form| form[key] = value }
    end

    def with_params(params)
      self.class[method, path, params, query, headers, cookies, form, session, raw]
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

    def with_cookie(name, value, path: "/", http_only: true, same_site: "Lax", secure: false)
      directives = ["#{name}=#{URI.encode_www_form_component(value)}", "Path=#{path}", "SameSite=#{same_site}"]
      directives << "HttpOnly" if http_only
      directives << "Secure" if secure

      with_header("set-cookie", directives.join("; "))
    end

    def with_session(request)
      with_cookie(SESSION_COOKIE, SessionCookie.encode(request.session))
    end
  end

  module SessionCookie
    module_function

    def encode(session)
      payload = JSON.generate(session)
      nonce = RbNaCl::Random.random_bytes(RbNaCl::SecretBox.nonce_bytes)
      encrypted = secret_box.encrypt(nonce, payload)

      encode64("#{nonce}#{encrypted}")
    end

    def decode(cookie)
      return {} if cookie.to_s.empty?

      payload = decode64(cookie)
      nonce = payload.byteslice(0, RbNaCl::SecretBox.nonce_bytes)
      encrypted = payload.byteslice(RbNaCl::SecretBox.nonce_bytes..)

      JSON.parse(secret_box.decrypt(nonce, encrypted))
    rescue ArgumentError, JSON::ParserError, RbNaCl::CryptoError
      {}
    end

    def secret_box
      @secret_box ||= RbNaCl::SecretBox.new(RbNaCl::Hash.sha256(SESSION_SECRET))
    end

    def encode64(value)
      [value].pack("m0").tr("+/", "-_").delete("=")
    end

    def decode64(value)
      value = value.tr("-_", "+/")
      value = value.ljust(value.length + ((4 - value.length) % 4), "=")
      value.unpack1("m0")
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
