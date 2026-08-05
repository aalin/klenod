# frozen_string_literal: true

require "protocol/url"

module Klenod
  module Build
    class ModuleId
      SCHEME_PATTERN = /\A[A-Za-z][A-Za-z0-9+.-]*:/

      def self.parse(value)
        new(value)
      end

      def initialize(value, query = nil)
        @url = absolute_url_for(value.to_s)
        @url = @url.with(query: query) if query

        @scheme = @url.scheme.to_sym
        @host = @url.authority
        @uri_path = absolute_uri_path(@url.path)
        @query = @url.query
      end

      attr_reader :scheme, :host, :uri_path, :query

      def merge(specifier)
        specifier = specifier.to_s
        return self.class.parse(specifier) if explicit_scheme?(specifier)

        self.class.parse((@url + Protocol::URL[specifier]).to_s)
      end

      def to_s
        @url.to_s
      end

      def path
        case scheme
        when :app
          relative_path
        when :virtual
          "virtual:#{relative_path}"
        else
          host ? "#{scheme}://#{host}#{uri_path}" : "#{scheme}:#{relative_path}"
        end
      end

      def relative_path
        uri_path.delete_prefix("/")
      end
      alias_method :bare_path, :relative_path

      def dirname
        File.dirname(relative_path)
      end

      def extname
        File.extname(uri_path)
      end

      def eql?(other)
        other.is_a?(self.class) && to_s == other.to_s
      end
      alias_method :==, :eql?

      def hash
        to_s.hash
      end

      private

      def absolute_url_for(value)
        parsed = Protocol::URL[value]
        return absolute_url(parsed) if parsed.respond_to?(:scheme) && parsed.scheme

        Protocol::URL::Absolute.new("app", nil, absolute_uri_path(parsed.path), parsed.query, parsed.fragment)
      end

      def absolute_url(parsed)
        Protocol::URL::Absolute.new(
          parsed.scheme,
          parsed.authority,
          absolute_uri_path(parsed.path),
          parsed.query,
          parsed.fragment
        )
      end

      def absolute_uri_path(path)
        path = path.to_s
        path = "/#{path}" unless path.start_with?("/")
        path
      end

      def explicit_scheme?(value)
        value.match?(SCHEME_PATTERN)
      end
    end
  end
end
