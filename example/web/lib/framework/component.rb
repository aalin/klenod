# frozen_string_literal: true

module Example
  class Component
    attr_reader :__slots

    def self.instantiate(**props)
      slots = props.delete(:slots)
      children = props[:children]
      slots = children.slots if children.is_a?(H::Children)
      slots = H::Slots.new(slots, children: children) unless slots.is_a?(H::Slots)
      props[:children] = H::Children.new(slots) unless children.is_a?(H::Children)

      instance = allocate
      instance.instance_variable_set(:@__props, props.freeze)
      instance.instance_variable_set(:@__slots, slots)

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

    def provide_context(**values, &producer)
      H.context(**values, &producer)
    end

    def prop?(name)
      !!prop_key(name)
    end

    def prop(name, default = nil)
      key = prop_key(name)
      key ? @__props.fetch(key) : default
    end

    def initialize(**)
    end

    private

    def prop_key(name)
      return name if @__props.key?(name)

      symbol_name = name.to_sym if name.respond_to?(:to_sym)
      symbol_name if symbol_name && @__props.key?(symbol_name)
    end
  end
end
