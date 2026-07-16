# frozen_string_literal: true

require "http/accept/languages"

module Example
  class I18n
    DEFAULT_LOCALE = "en-US"
    @missing_keys = Set.new
    @default_locale = DEFAULT_LOCALE

    attr_reader :translations

    def initialize(owner = nil, translations = nil, default_locale: self.class.default_locale)
      @owner = owner
      @translations = translations || translations_for(owner)
      @source = owner.module_path if owner&.respond_to?(:module_path)
      @default_locale = default_locale
    end

    def t(*key, locale: nil, default: nil, **values)
      self.class.t(@translations, *key, locale: locale, default: default, source: @source, default_locale: @default_locale, **values)
    end

    def lang
      self.class.resolve_locale(@translations, default_locale: @default_locale)
    end

    def self.default_locale
      @default_locale
    end

    def self.default_locale=(locale)
      @default_locale = locale.to_s
    end

    def self.t(translations, *key, locale: nil, default: nil, source: nil, default_locale: self.default_locale, **values)
      key = normalize_key(key)
      locale ||= resolve_locale(translations, default_locale: default_locale)
      value = lookup(translations.fetch(locale, {}), key)
      value = pluralize(value, values)
      return interpolate(value, values) unless value.nil?

      fallback = key_fallback_locale(translations, locale, default_locale: default_locale)
      value = lookup(translations.fetch(fallback, {}), key) if fallback
      value = pluralize(value, values)
      unless value.nil?
        warn_missing(key, locale:, fallback:, source:)
        return interpolate(value, values)
      end

      warn_missing(key, locale:, fallback:, source:)
      value = default || key.join(".")
      interpolate(value, values)
    end

    def self.resolve_locale(translations, request: Context.current&.request, default_locale: self.default_locale)
      available = translations.keys.map(&:to_s)
      return default_locale if available.empty?

      cookie_locale = request&.cookies&.fetch(LOCALE_COOKIE, nil).to_s
      return cookie_locale if available.include?(cookie_locale)
      return fallback_locale(translations, cookie_locale) if !cookie_locale.empty? && fallback_locale(translations, cookie_locale)

      requested = preferred_locales(request, default_locale: default_locale)
      requested.filter_map { |language| fallback_locale(translations, language.locale) }.first || fallback_locale(translations, default_locale) || available.first
    end

    def self.preferred_locales(request, default_locale: self.default_locale)
      header = request&.headers&.fetch("accept-language", nil).to_s
      return [HTTP::Accept::Languages::LanguageRange.new(default_locale, nil)] if header.empty?

      HTTP::Accept::Languages.parse(header)
    rescue HTTP::Accept::ParseError
      [HTTP::Accept::Languages::LanguageRange.new(default_locale, nil)]
    end

    def self.lookup(values, key)
      key.reduce(values) do |current, part|
        return nil unless current.respond_to?(:fetch)

        current.fetch(part, nil)
      end
    end

    def self.normalize_key(key)
      key.flatten.flat_map { |part| part.to_s.split(".") }
    end

    def self.pluralize(value, values)
      return value unless value.is_a?(Hash) && values.key?(:count)

      count = values.fetch(:count)
      key =
        if count.to_i == 0 && value.key?("zero")
          "zero"
        elsif count.to_i == 1
          "one"
        else
          "other"
        end
      value.fetch(key, nil)
    end

    def self.interpolate(value, values)
      return value unless value.is_a?(String) && !values.empty?

      value.gsub(/%\{([a-zA-Z_][a-zA-Z0-9_]*)\}/) do
        name = Regexp.last_match(1).to_sym
        values.fetch(name) { "%{#{name}}" }.to_s
      end
    end

    def self.fallback_locale(translations, locale)
      available = translations.keys.map(&:to_s)
      return locale if available.include?(locale)

      language = locale.to_s.split("-", 2).fetch(0)
      available.find { |candidate| candidate == language || candidate.start_with?("#{language}-") }
    end

    def self.key_fallback_locale(translations, locale, default_locale: self.default_locale)
      available = translations.keys.map(&:to_s)
      [
        fallback_locale(translations, default_locale),
        available.find { |candidate| candidate != locale.to_s }
      ].compact.find { |candidate| candidate != locale.to_s }
    end

    def self.valid_locale?(translations, locale)
      available = translations.keys.map(&:to_s)
      available.include?(locale.to_s) || !!fallback_locale(translations, locale.to_s)
    end

    def self.warn_missing(key, locale:, fallback:, source:)
      warning = [source, locale, fallback, key]
      return if @missing_keys.include?(warning)

      @missing_keys << warning
      location = source ? " in #{source}" : ""
      fallback_text = fallback ? "; falling back to #{fallback}" : ""
      warn "Missing translation #{key.join(".").inspect} for #{locale}#{location}#{fallback_text}"
    end

    private

    def translations_for(owner)
      if owner&.const_defined?(:Translations, false)
        owner.const_get(:Translations)
      else
        {}
      end
    end
  end
end

I18n = Example::I18n unless defined?(I18n)
