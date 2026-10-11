# frozen_string_literal: true

require "digest"

module Klenod
  module Runtime
    module Generated
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

      FROZEN_STRING_LITERAL_PREFIX = "# frozen_string_literal: true\n"
      MAGIC_COMMENT_PATTERN = /\A#.*\b(?:frozen_string_literal|(?:en)?coding)\s*[:=]/i

      attr_reader :path, :source, :source_map, :version, :constant_name, :eval_path, :namespace

      def self.constant_name_for(path)
        "Mod_#{Digest::SHA256.hexdigest(path)[0, 24]}"
      end

      def inspect
        "Mod(#{path.inspect})"
      end

      def initialize(path, source, imports: {}, source_map: nil, version: 0, constant_name: nil, eval_path: nil, namespace: Generated)
        @path = path
        @source = source
        @imports = imports
        @source_map = source_map
        @version = version
        @constant_name = constant_name || self.class.constant_name_for(path)
        @eval_path = eval_path || path
        @namespace = namespace
        register_constant
        create_exports
      end

      def marshal_dump
        [@path, @source, @source_map, @version, @constant_name, @eval_path]
      end

      def marshal_load(data)
        @path, @source, @source_map, @version, @constant_name, @eval_path = data
        @eval_path ||= @path
        @namespace = Generated
        @imports = {}
        register_constant
        create_exports
      end

      def to_s
        "#<#{self.class.name} path=#{@path.inspect}>"
      end

      private

      def register_constant
        @namespace.__send__(:remove_const, @constant_name) if @namespace.const_defined?(@constant_name, false)
        @namespace.const_set(@constant_name, self)
      end

      def create_exports
        remove_const(:Exports) if const_defined?(:Exports, false)

        exports = Exports.new(self, @imports)
        const_set(:Exports, exports)
        exports.module_eval(*evaluated_source)
      end

      # Modules are evaluated with frozen string literals unless their leading
      # comments set a magic comment themselves. The prefix is evaluated as
      # line 0, so every line keeps its number in backtraces and coverage.
      def evaluated_source
        return [@source, @eval_path, 1] if leading_magic_comment?

        [FROZEN_STRING_LITERAL_PREFIX + @source, @eval_path, 0]
      end

      def leading_magic_comment?
        @source.each_line do |line|
          stripped = line.strip
          next if stripped.empty?
          return false unless stripped.start_with?("#")
          return true if stripped.match?(MAGIC_COMMENT_PATTERN)
        end

        false
      end
    end
  end
end
