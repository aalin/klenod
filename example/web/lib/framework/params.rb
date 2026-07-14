# frozen_string_literal: true

require "strscan"

module Example
  module Params
    module_function

    def parse(pairs)
      pairs.each_with_object({}) do |(key, value), params|
        assign(params, keys_for(key), value)
      end
    end

    def keys_for(name)
      keys = []
      scanner = StringScanner.new(name)
      keys << scanner.scan(/[^\[]+/).to_s
      keys << scanner[1] while scanner.scan(/\[([^\]]*)\]/)
      keys
    end

    def assign(container, keys, value)
      key = keys.fetch(0)
      rest = keys.drop(1)

      if rest.empty?
        assign_value(container, key, value)
      elsif key.empty?
        target = array_child(container, rest.fetch(0))
        assign(target, rest, value)
      else
        container[key] ||= rest.fetch(0).empty? ? [] : {}
        assign(container[key], rest, value)
      end
    end

    def assign_value(container, key, value)
      if key.empty?
        container << value
      elsif container.key?(key)
        container[key] = [container[key]] unless container[key].is_a?(Array)
        container[key] << value
      else
        container[key] = value
      end
    end

    def array_child(array, next_key)
      if next_key.empty?
        array
      else
        child = array.last
        child = nil unless child.is_a?(Hash) && !child.key?(next_key)
        child || array.tap { array << {} }.last
      end
    end
  end
end
