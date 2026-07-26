# frozen_string_literal: true

module Example
  class Component
    attr_reader :__slots

    def self.instantiate(**props)
      instance = allocate
      instance.instance_variable_set(:@__props, props.freeze)
      instance.instance_variable_set(:@__slots, props.fetch(:slots, {}).freeze)

      parameters = instance.method(:initialize).parameters
      if parameters.empty?
        instance.send(:initialize)
      else
        instance.send(:initialize, **initialize_props(props, parameters))
      end

      instance
    end

    def self.initialize_props(props, parameters)
      props = props.except(:slots)
      return props if parameters.any? { |kind, _name| kind == :keyrest }

      accepted = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
      props.slice(*accepted)
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

    def children
      @__props[:children]
    end

    def initialize(**props)
      @__props = (@__props || {}).merge(props).freeze
      @__slots = (@__slots || props.fetch(:slots, {})).freeze
    end
  end
end
