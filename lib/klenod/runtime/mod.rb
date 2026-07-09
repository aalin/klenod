# frozen_string_literal: true

require "digest"

module Klenod
  module Runtime
    module Generated
    end

    def self.class_names(*values)
      classes =
        values.flat_map do |value|
          case value
          when nil, false
            []
          when Array
            class_names(*value)&.split || []
          when Hash
            value.filter_map { |class_name, enabled| class_name if enabled }
          else
            value.to_s.split
          end
        end

      classes.empty? ? nil : classes.join(" ")
    end

    class LazyImport
      def initialize(&loader)
        @loader = loader
        @loaded = false
        @value = nil
      end

      def call
        return @value if @loaded

        @value = @loader.call
        @loaded = true
        @value
      end

      alias_method :value, :call

      def loaded?
        @loaded
      end

      def reset!
        @loaded = false
        @value = nil
        self
      end
    end

    class Mod < Module
      class Exports < Module
        def initialize(mod, imports)
          @mod = mod
          @imports = imports
        end

        def inspect
          "#{@mod.inspect}::Exports"
        end

        def __klenod_import__(dependency_id)
          @imports.fetch(dependency_id)
        end

        def __klenod_lazy_import__(dependency_id)
          @imports.fetch(dependency_id)
        end
      end

      attr_reader :path, :source, :source_map, :version, :constant_name

      def self.constant_name_for(path)
        "Mod_#{Digest::SHA256.hexdigest(path)[0, 24]}"
      end

      def inspect
        "Mod(#{path.inspect})"
      end

      def initialize(path, source, imports: {}, source_map: nil, version: 0, constant_name: nil)
        @path = path
        @source = source
        @imports = imports
        @source_map = source_map
        @version = version
        @constant_name = constant_name || self.class.constant_name_for(path)
        register_constant
        create_exports
      end

      def marshal_dump
        [@path, @source, @source_map, @version, @constant_name]
      end

      def marshal_load(data)
        @path, @source, @source_map, @version, @constant_name = data
        @imports = {}
        register_constant
        create_exports
      end

      def to_s
        "#<#{self.class.name} path=#{@path.inspect}>"
      end

      private

      def register_constant
        Generated.__send__(:remove_const, @constant_name) if Generated.const_defined?(@constant_name, false)
        Generated.const_set(@constant_name, self)
      end

      def create_exports
        remove_const(:Exports) if const_defined?(:Exports, false)

        exports = Exports.new(self, @imports)
        exports.module_eval(@source, @path, 1)
        const_set(:Exports, exports)
      end
    end
  end
end
