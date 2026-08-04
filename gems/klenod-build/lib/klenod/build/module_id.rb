# frozen_string_literal: true

module Klenod
  module Build
    class ModuleId
      SCHEME_PATTERN = /\A[A-Za-z][A-Za-z0-9+.-]*:/

      def self.parse(value)
        new(value)
      end

      def initialize(value, query = nil)
        value, parsed_query = value.to_s.split("?", 2)
        query ||= parsed_query

        @scheme, @host, @uri_path = parse_uri_parts(value)
        @query = query
      end

      attr_reader :scheme, :host, :uri_path, :query

      def merge(specifier)
        specifier = specifier.to_s
        return self.class.parse(specifier) if specifier.match?(SCHEME_PATTERN)

        path, query = specifier.split("?", 2)
        merged_path =
          if path.empty?
            uri_path
          elsif path.start_with?("/")
            path
          else
            File.expand_path(path, File.dirname(uri_path))
          end

        self.class.new(uri_string(scheme, host, merged_path), query)
      end

      def to_s
        result =
          if host
            "#{scheme}://#{host}#{uri_path}"
          else
            "#{scheme}:#{uri_path}"
          end
        query ? "#{result}?#{query}" : result
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

      def parse_uri_parts(value)
        if value.match?(SCHEME_PATTERN)
          parse_explicit_uri(value)
        else
          [:app, nil, absolute_uri_path(value)]
        end
      end

      def parse_explicit_uri(value)
        scheme_string, rest = value.split(":", 2)
        scheme = scheme_string.to_sym

        if rest.start_with?("//")
          host, path = rest.delete_prefix("//").split("/", 2)
          [scheme, host, absolute_uri_path(path)]
        else
          [scheme, nil, absolute_uri_path(rest)]
        end
      end

      def absolute_uri_path(path)
        path = path.to_s
        path = "/#{path}" unless path.start_with?("/")
        path
      end

      def uri_string(scheme, host, path)
        if host
          "#{scheme}://#{host}#{absolute_uri_path(path)}"
        else
          "#{scheme}:#{absolute_uri_path(path)}"
        end
      end
    end
  end
end
