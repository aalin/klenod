module Klenod
  class Mod < Module
    class Exports < Module
      def initialize(mod)
        @mod = mod
      end

      def inspect
        "#{@mod.inspect}::Exports"
      end
    end

    using ImportRefinements

    attr_reader :version
    attr_reader :path

    def inspect
      "Mod(#{path.inspect})"
    end

    def initialize(path, source, version: 0)
      @path = path
      @source = source
      @version = version
      create_exports
    end

    def marshal_dump
      [@path, @source, @version]
    end

    def marshal_load(data)
      @path, @source, @version = data
      create_exports
    end

    def to_s
      "#<#{self.class.name} path=#{@path.inspect}>"
    end

    private

    def create_exports
      exports = Exports.new(self)
      exports.module_eval(@source, @path, 1)
      const_set(:Exports, exports)
    end
  end
end
