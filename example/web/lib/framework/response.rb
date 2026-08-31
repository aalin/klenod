# frozen_string_literal: true

require "json"
require "uri"

module Example
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

    def self.markdown(value, status: 200, headers: {})
      self[
        status,
        {"content-type" => "text/markdown; charset=utf-8"}.merge(headers),
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
end
