# frozen_string_literal: true

module Example
  class Component
    def context
      Context.current
    end

    def request
      context&.request
    end

    def self.i18n
      @i18n ||= I18n.new(self)
    end

    def i18n
      self.class.i18n
    end

    def t(*key, default: nil)
      i18n.t(*key, default: default)
    end

    def initialize(...)
    end
  end
end
