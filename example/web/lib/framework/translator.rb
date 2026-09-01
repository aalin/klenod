# frozen_string_literal: true

module Example
  class Translator
    DEFAULT_LOCALE = "en-US"

    attr_reader :translations

    def initialize(owner = nil, translations: nil, default_locale: DEFAULT_LOCALE)
      @translations = translations || translations_for(owner)
      @source = owner.module_path if owner&.respond_to?(:module_path)
      @default_locale = default_locale.to_s
      @missing_keys = Set.new
      @missing_interpolations = Set.new
    end

    def t(*key, locale: nil, default: nil, **values)
      key = normalize_key(key)
      locale ||= resolve_locale
      value = lookup(translations.fetch(locale, {}), key)
      value = pluralize(value, values)
      return interpolate(value, values, locale:, key:) unless value.nil?

      fallback = key_fallback_locale(locale)
      value = lookup(translations.fetch(fallback, {}), key) if fallback
      value = pluralize(value, values)
      unless value.nil?
        warn_missing(key, locale:, fallback:)
        return interpolate(value, values, locale: fallback, key:)
      end

      warn_missing(key, locale:, fallback:)
      value = default || key.join(".")
      interpolate(value, values, locale:, key:)
    end

    def lang
      resolve_locale
    end

    private

    def resolve_locale(request: Context.current&.request)
      available = translations.keys.map(&:to_s)
      return @default_locale if available.empty?

      locale = request&.locale || @default_locale
      fallback_locale(locale) || fallback_locale(@default_locale) || available.first
    end

    def lookup(values, key)
      key.reduce(values) do |current, part|
        return nil unless current.respond_to?(:fetch)

        current.fetch(part, nil)
      end
    end

    def normalize_key(key)
      key.flatten.flat_map { |part| part.to_s.split(".") }
    end

    def pluralize(value, values)
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

    def interpolate(value, values, locale:, key:)
      return value unless value.is_a?(String)

      value.gsub(/%\{([a-zA-Z_][a-zA-Z0-9_]*)\}/) do
        name = Regexp.last_match(1).to_sym
        if values.key?(name)
          values.fetch(name).to_s
        else
          warn_missing_interpolation(name, locale:, key:)
          "%{#{name}}"
        end
      end
    end

    def fallback_locale(locale)
      available = translations.keys.map(&:to_s)
      return locale if available.include?(locale)

      language = locale.to_s.split("-", 2).fetch(0)
      available.find { |candidate| candidate == language || candidate.start_with?("#{language}-") }
    end

    def key_fallback_locale(locale)
      available = translations.keys.map(&:to_s)
      [
        fallback_locale(@default_locale),
        available.find { |candidate| candidate != locale.to_s }
      ].compact.find { |candidate| candidate != locale.to_s }
    end

    def warn_missing(key, locale:, fallback:)
      return unless @missing_keys.add?([locale, fallback, key])

      location = @source ? " in #{@source}" : ""
      fallback_text = fallback ? "; falling back to #{fallback}" : ""
      warn format_warning("Missing translation #{key.join(".").inspect} for #{locale}#{location}#{fallback_text}")
    end

    def warn_missing_interpolation(name, locale:, key:)
      return unless @missing_interpolations.add?([locale, key, name])

      location = @source ? " in #{@source}" : ""
      warn format_warning("Missing interpolation #{name.inspect} for #{key.join(".").inspect} in #{locale}#{location}")
    end

    def format_warning(message)
      return "WARNING #{message}" if ENV["NO_COLOR"]

      "\e[1;30;43m WARNING \e[0m \e[1;33m#{message}\e[0m"
    end

    def translations_for(owner)
      if owner&.const_defined?(:Translations, false)
        owner.const_get(:Translations)
      else
        {}
      end
    end
  end
end
