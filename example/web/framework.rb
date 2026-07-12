# frozen_string_literal: true

require "cgi/escape"
require "json"
require "rbnacl"
require "strscan"
require "uri"

module Example
  SESSION_COOKIE = "klenod_example_session"
  SESSION_SECRET = ENV.fetch("KLENOD_EXAMPLE_SESSION_SECRET", "klenod example development session secret")
  CSRF_TOKEN_KEY = "_csrf_token"
  CONTEXT_KEY = :example_web_context

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
        Session.new(SessionCookie.decode(cookies[SESSION_COOKIE])),
        raw
      ]
    end

    def self.parse_query(query_string)
      return {} if query_string.to_s.empty?

      Params.parse(URI.decode_www_form(query_string))
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
        begin
          loop do
            chunk = body.read
            break unless chunk

            chunks << chunk
          end
        ensure
          body.close if body.respond_to?(:close)
        end
        return chunks.join
      end

      body.to_s
    end

    def self.parse_form(body)
      return {} if body.to_s.empty?

      Params.parse(URI.decode_www_form(body))
    end

    def with_params(params)
      self.class[method, path, params, query, headers, cookies, form, session, raw]
    end

    def csrf_token
      session[CSRF_TOKEN_KEY] ||= SessionCookie.encode64(RbNaCl::Random.random_bytes(32))
    end
  end

  class Session
    def initialize(values = {})
      @values = values
      @dirty = false
    end

    def [](key)
      @values[key]
    end

    def []=(key, value)
      @dirty = true unless @values[key] == value
      @values[key] = value
    end

    def fetch(...)
      @values.fetch(...)
    end

    def delete(key)
      @dirty = true if @values.key?(key)
      @values.delete(key)
    end

    def dirty?
      @dirty
    end

    def to_h
      @values
    end
  end

  module Params
    module_function

    def parse(pairs)
      pairs.each_with_object({}) do |(key, value), params|
        assign(params, keys_for(key), value)
      end
    end

    def keys_for(name)
      keys = []
      scanner = StringScanner.new(name)
      keys << scanner.scan(/[^\[]+/).to_s
      keys << scanner[1] while scanner.scan(/\[([^\]]*)\]/)
      keys
    end

    def assign(container, keys, value)
      key = keys.fetch(0)
      rest = keys.drop(1)

      if rest.empty?
        assign_value(container, key, value)
      elsif key.empty?
        target = array_child(container, rest.fetch(0))
        assign(target, rest, value)
      else
        container[key] ||= rest.fetch(0).empty? ? [] : {}
        assign(container[key], rest, value)
      end
    end

    def assign_value(container, key, value)
      if key.empty?
        container << value
      elsif container.key?(key)
        container[key] = [container[key]] unless container[key].is_a?(Array)
        container[key] << value
      else
        container[key] = value
      end
    end

    def array_child(array, next_key)
      if next_key.empty?
        array
      else
        child = array.last
        child = nil unless child.is_a?(Hash) && !child.key?(next_key)
        child || array.tap { array << {} }.last
      end
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

    def delete_cookie(name, path: "/", http_only: true, same_site: "Lax", secure: false)
      directives = ["#{name}=", "Path=#{path}", "Max-Age=0", "SameSite=#{same_site}"]
      directives << "HttpOnly" if http_only
      directives << "Secure" if secure

      with_header("set-cookie", directives.join("; "))
    end

    def with_session(request)
      with_cookie(SESSION_COOKIE, SessionCookie.encode(request.session))
    end

    def delete_session
      delete_cookie(SESSION_COOKIE)
    end
  end

  module CSRF
    SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

    module_function

    def valid?(request)
      return true if SAFE_METHODS.include?(request.method)

      token = request.session[CSRF_TOKEN_KEY]
      submitted = request.form["csrf_token"] || request.headers["x-csrf-token"]
      secure_compare(token, submitted)
    end

    def secure_compare(left, right)
      return false if left.to_s.empty? || right.to_s.empty?

      left_bytes = left.to_s.unpack("C*")
      right_bytes = right.to_s.unpack("C*")
      return false unless left_bytes.length == right_bytes.length

      left_bytes.zip(right_bytes).reduce(0) { |result, (a, b)| result | (a ^ b) } == 0
    end
  end

  module SessionCookie
    module_function

    def encode(session)
      payload = JSON.generate(session.to_h)
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

  Context = Data.define(:request, :parent) do
    def self.current
      Thread.current[CONTEXT_KEY]
    end

    def self.with(request: nil)
      previous = current
      Thread.current[CONTEXT_KEY] = new(request || previous&.request, previous)
      yield
    ensure
      Thread.current[CONTEXT_KEY] = previous
    end
  end

  class Component
    def context
      Context.current
    end

    def request
      context&.request
    end

    def initialize(...)
    end
  end

  class Form < Component
    def initialize(action:, method: "get", children: [], **props)
      @action = action
      @method = method
      @children = children
      @props = props
    end

    def render
      H[
        :form,
        csrf_field,
        *@children,
        **@props.merge(action: @action, method: @method)
      ]
    end

    def csrf_field
      return nil if %w[get head].include?(@method.to_s.downcase)

      H[:input, type: "hidden", name: "csrf_token", value: request.csrf_token]
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
