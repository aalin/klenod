# frozen_string_literal: true

require "http/accept/languages"

module Example
  module I18n
    DEFAULT_LOCALE = "en-US"

    def self.t(translations, key, locale: nil, default: nil)
      locale ||= resolve_locale(translations)
      value = lookup(translations.fetch(locale, {}), key)
      return value unless value.nil?

      fallback = fallback_locale(translations, locale)
      value = lookup(translations.fetch(fallback, {}), key) if fallback
      value.nil? ? default || key.to_s : value
    end

    def self.resolve_locale(translations, request: Context.current&.request)
      available = translations.keys.map(&:to_s)
      return DEFAULT_LOCALE if available.empty?

      requested = preferred_locales(request)
      matched = HTTP::Accept::Languages::Locales.new(available) & requested
      matched.first || fallback_locale(translations, DEFAULT_LOCALE) || available.first
    end

    def self.preferred_locales(request)
      header = request&.headers&.fetch("accept-language", nil).to_s
      return [HTTP::Accept::Languages::LanguageRange.new(DEFAULT_LOCALE, nil)] if header.empty?

      HTTP::Accept::Languages.parse(header)
    rescue HTTP::Accept::ParseError
      [HTTP::Accept::Languages::LanguageRange.new(DEFAULT_LOCALE, nil)]
    end

    def self.lookup(values, key)
      key.to_s.split(".").reduce(values) do |current, part|
        return nil unless current.respond_to?(:fetch)

        current.fetch(part, nil)
      end
    end

    def self.fallback_locale(translations, locale)
      available = translations.keys.map(&:to_s)
      return locale if available.include?(locale)

      language = locale.to_s.split("-", 2).fetch(0)
      available.find { |candidate| candidate == language || candidate.start_with?("#{language}-") }
    end
  end
end

I18n = Example::I18n unless defined?(I18n)
