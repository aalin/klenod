# frozen_string_literal: true

require "uri"

module Klenod
  module Runtime
    module AssetUrl
      DEFAULT_BASE = "/assets/"
      LEGACY_OUTPUT_PREFIX = "/assets/"

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
        path = output_path.to_s
        unless path.start_with?("/") && !path.start_with?("//")
          raise ArgumentError, "asset output path must be root-relative: #{output_path.inspect}"
        end

        "#{normalize(base)}#{path.delete_prefix("/")}"
      end

      def legacy_join(base, output_path)
        join(base, output_path.delete_prefix(LEGACY_OUTPUT_PREFIX).prepend("/"))
      end

      def path_prefix(base)
        normalized = normalize(base)
        normalized if normalized.start_with?("/")
      end
    end
  end
end
