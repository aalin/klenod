# frozen_string_literal: true

require "rbnacl"
require "uri"

module Example
  Request = Data.define(:method, :path, :params, :query, :headers, :cookies, :form, :session, :raw, :canonical_path, :locale, :route_locale) do
    def self.from(raw, params: {}, localized: nil)
      raw_path = raw&.path.to_s
      raw_path = "/" if raw_path.empty?
      path, query_string = raw_path.split("?", 2)
      headers = headers_from(raw)
      cookies = parse_cookies(headers.fetch("cookie", nil))
      form = parse_form(read_body(raw))

      self[
        request_method(raw, form),
        path.empty? ? "/" : path,
        params,
        parse_query(query_string),
        headers,
        cookies,
        form,
        Session.new(SessionCookie.decode(cookies[SESSION_COOKIE])),
        raw,
        localized&.path || (path.empty? ? "/" : path),
        localized&.locale,
        localized&.route_locale
      ]
    end

    def self.request_method(raw, form)
      method = raw&.method.to_s.empty? ? "GET" : raw.method.to_s.upcase
      return method unless method == "POST"

      override = form.fetch("_method", "").to_s.upcase
      %w[PUT PATCH DELETE].include?(override) ? override : method
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
      self.class[method, path, params, query, headers, cookies, form, session, raw, canonical_path, locale, route_locale]
    end

    def csrf_token
      session[CSRF_TOKEN_KEY] ||= SessionCookie.encode64(RbNaCl::Random.random_bytes(32))
    end
  end
end
