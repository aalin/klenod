# frozen_string_literal: true

module Example
  class Component
    def context
      Context.current
    end

    def request
      context&.request
    end

    def t(key, default: nil)
      translations =
        if self.class.const_defined?(:Translations, false)
          self.class.const_get(:Translations)
        else
          {}
        end

      source = self.class.module_path if self.class.respond_to?(:module_path)
      I18n.t(translations, key, default: default, source: source)
    end

    def initialize(...)
    end
  end
end
