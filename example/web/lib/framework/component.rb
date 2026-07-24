# frozen_string_literal: true

module Example
  class Component
    def self.instantiate(**props)
      instance = allocate
      instance.instance_variable_set(:@__props, props.freeze)

      if instance.method(:initialize).parameters.empty?
        instance.send(:initialize)
      else
        instance.send(:initialize, **props)
      end

      instance
    end

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

    def localized_path(...)
      context.routes.localized_path(...)
    end

    def initialize(**props)
      @__props = props.freeze
    end
  end
end
