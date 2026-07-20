# frozen_string_literal: true

require "http/accept/languages"

module Example
  class LocalizedRoutes
    LOCALE_PATTERN = /\A[a-z]{2,3}(?:-[A-Za-z]{2})?\z/

    LocalizedPath = Data.define(:path, :visible_path, :locale, :route_locale)

    def initialize(routes:, translations:, default_locale: "en")
      @routes = routes
      @translations = normalize_translations(translations)
      @default_locale = default_locale.to_s
    end

    attr_reader :default_locale

    def canonicalize_path(path, headers: {}, cookies: {})
      visible_path = normalized_path(path)
      parts = path_parts(visible_path)
      prefix = locale_prefix(parts)
      preferred_locale = preferred_locale(headers:, cookies:)
      locale = prefix&.fetch(:locale) || preferred_locale
      route_locale = prefix&.fetch(:route_locale) || route_locale_for(default_locale)
      match_parts = prefix ? parts.drop(1) : parts
      canonical = canonical_path_for(match_parts, route_locale) || visible_path

      LocalizedPath.new(canonical, visible_path, locale, route_locale)
    end

    def localized_path(pattern, locale: nil, **params)
      requested_locale = (locale || Context.current&.request&.locale || default_locale).to_s
      route_locale = route_locale_for(requested_locale) || route_locale_for(default_locale)
      prefix = locale_prefix_for(requested_locale, route_locale)
      parts = localized_parts_for(pattern, route_locale, params)

      path = "/#{[*prefix, *parts].join("/")}"
      (path == "/") ? path : path.delete_suffix("/")
    end

    private

    def normalize_translations(translations)
      translations.to_h do |locale, value|
        segments = value.fetch("segments", value.fetch(:segments, {}))
        [locale.to_s, segments.transform_keys(&:to_s).transform_values(&:to_s)]
      end
    end

    def normalized_path(path)
      value = path.to_s.split("?", 2).first
      value = "/" if value.empty?
      value.start_with?("/") ? value : "/#{value}"
    end

    def path_parts(path)
      normalized_path(path).split("/").reject(&:empty?)
    end

    def locale_prefix(parts)
      first = parts.first.to_s
      return nil unless first.match?(LOCALE_PATTERN)

      route_locale = route_locale_for(first)
      return nil unless route_locale || ui_locale_supported?(first)

      {locale: first, route_locale: route_locale || route_locale_for(default_locale)}
    end

    def ui_locale_supported?(locale)
      route_locale_for(locale) || locale_language(locale) == locale_language(default_locale)
    end

    def preferred_locale(headers:, cookies:)
      cookie_locale = cookies.fetch(LOCALE_COOKIE, "").to_s
      return cookie_locale unless cookie_locale.empty?

      preferred_locales(headers.fetch("accept-language", nil).to_s).find do |locale|
        route_locale_for(locale) || locale_language(locale) == locale_language(default_locale)
      end || default_locale
    end

    def preferred_locales(header)
      return [default_locale] if header.empty?

      HTTP::Accept::Languages.parse(header).map(&:locale)
    rescue HTTP::Accept::ParseError
      [default_locale]
    end

    def route_locale_for(locale)
      value = locale.to_s
      return value if @translations.key?(value)

      language = locale_language(value)
      @translations.keys.find { |candidate| candidate == language || locale_language(candidate) == language }
    end

    def locale_language(locale)
      locale.to_s.split("-", 2).fetch(0)
    end

    def locale_prefix_for(requested_locale, route_locale)
      return [] if route_locale == route_locale_for(default_locale)

      [requested_locale]
    end

    def canonical_path_for(parts, route_locale)
      @routes.each do |route|
        canonical = canonical_path_for_route(route, parts, route_locale)
        return canonical if canonical
      end

      nil
    end

    def canonical_path_for_route(route, parts, route_locale)
      cursor = 0
      canonical_parts = []

      route.match_parts.each do |match_part|
        kind, path_part, _param_name = match_part
        case kind
        when :static
          return nil unless parts[cursor] == translate_segment(path_part, route_locale)

          canonical_parts << path_part
          cursor += 1
        when :dynamic
          return nil unless parts[cursor]

          canonical_parts << parts[cursor]
          cursor += 1
        when :catch_all
          return nil if parts[cursor..].empty?

          canonical_parts.concat(parts[cursor..])
          cursor = parts.length
        when :optional_catch_all
          canonical_parts.concat(parts[cursor..])
          cursor = parts.length
        end
      end

      return nil unless cursor == parts.length

      "/#{canonical_parts.join("/")}"
    end

    def localized_parts_for(pattern, route_locale, params)
      path_parts(pattern).flat_map do |part|
        case part
        when "[locale]"
          []
        when /\A\[\[\.\.\.(?<name>[A-Za-z_]\w*)\]\]\z/
          Array(params.fetch(Regexp.last_match(:name).to_sym, []))
        when /\A\[\.\.\.(?<name>[A-Za-z_]\w*)\]\z/
          Array(params.fetch(Regexp.last_match(:name).to_sym))
        when /\A\[(?<name>[A-Za-z_]\w*)\]\z/
          params.fetch(Regexp.last_match(:name).to_sym).to_s
        else
          translate_segment(part, route_locale)
        end
      end
    end

    def translate_segment(segment, route_locale)
      @translations.fetch(route_locale, {}).fetch(segment.to_s, segment.to_s)
    end
  end
end
