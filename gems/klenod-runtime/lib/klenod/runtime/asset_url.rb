# frozen_string_literal: true

require "uri"

module Klenod
  module Runtime
    module AssetUrl
      DEFAULT_BASE = "/assets/"
      CANONICAL_PREFIX = "/assets/"

      module_function

      def normalize(base)
        value = base.to_s
        value = DEFAULT_BASE if value.empty?
        uri = URI.parse(value)

        if uri.scheme
          unless %w[http https].include?(uri.scheme) && uri.host && !uri.query && !uri.fragment
            raise ArgumentError, "asset base must be an absolute HTTP(S) URL without a query or fragment: #{base.inspect}"
          end
        elsif !value.start_with?("/") || uri.query || uri.fragment
          raise ArgumentError, "asset base must be an absolute path or HTTP(S) URL: #{base.inspect}"
        end

        value.end_with?("/") ? value : "#{value}/"
      rescue URI::InvalidURIError
        raise ArgumentError, "asset base must be an absolute path or HTTP(S) URL: #{base.inspect}"
      end

      def join(base, output_path)
        filename = output_path.to_s.delete_prefix(CANONICAL_PREFIX)
        raise ArgumentError, "asset output path must start with #{CANONICAL_PREFIX.inspect}: #{output_path.inspect}" if filename == output_path

        "#{normalize(base)}#{filename}"
      end

      def path_prefix(base)
        normalized = normalize(base)
        normalized if normalized.start_with?("/")
      end
    end
  end
end
