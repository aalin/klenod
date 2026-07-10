# frozen_string_literal: true

module Klenod
  module Build
    Config =
      Data.define(:source_dir, :entrypoints, :output, :assets_dir, :plugins, :mode, :base_dir) do
        def initialize(source_dir: "src", entrypoints: [], output: "dist/klenod.bundle", assets_dir: nil, plugins: Context::DEFAULT_PLUGINS, mode: :development, base_dir: Dir.pwd)
          super(
            source_dir: source_dir,
            entrypoints: Array(entrypoints),
            output: output,
            assets_dir: assets_dir,
            plugins: plugins,
            mode: mode,
            base_dir: base_dir
          )
        end

        def with(**attributes)
          self.class.new(**to_h.merge(attributes))
        end

        def context(**overrides)
          Context.new(
            source_dir: source_path,
            plugins: plugins,
            mode: mode,
            **overrides
          )
        end

        def source_path
          expand_path(source_dir)
        end

        def output_path
          expand_path(output)
        end

        def assets_path
          assets_dir && expand_path(assets_dir)
        end

        private

        def expand_path(path)
          path = path.to_s
          return File.expand_path(path) if path.start_with?("/")

          File.expand_path(path, base_dir)
        end
      end

    class ConfigBuilder
      def initialize(base_dir: Dir.pwd)
        @source_dir = "src"
        @entrypoints = []
        @output = "dist/klenod.bundle"
        @assets_dir = nil
        @plugins = Context::DEFAULT_PLUGINS
        @mode = :development
        @base_dir = base_dir
      end

      def source_dir(value = nil)
        return @source_dir unless value

        @source_dir = value
      end

      def entrypoint(value)
        @entrypoints << value
      end

      def entrypoints(*values)
        @entrypoints.concat(values.flatten)
      end

      def output(value = nil)
        return @output unless value

        @output = value
      end

      def assets_dir(value = nil)
        return @assets_dir unless value

        @assets_dir = value
      end

      def plugins(value = nil, &block)
        return @plugins unless value || block

        @plugins = block ? block.call : value
      end

      def mode(value = nil)
        return @mode unless value

        @mode = value
      end

      def config
        Config.new(
          source_dir: @source_dir,
          entrypoints: @entrypoints,
          output: @output,
          assets_dir: @assets_dir,
          plugins: @plugins,
          mode: @mode,
          base_dir: @base_dir
        )
      end
    end

    module ConfigLoader
      CONFIG_FILE = "klenod.config.rb"

      module_function

      def find(start_dir = Dir.pwd)
        dir = File.expand_path(start_dir)

        loop do
          path = File.join(dir, CONFIG_FILE)
          return path if File.file?(path)

          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end

      def load(path)
        builder = ConfigBuilder.new(base_dir: File.dirname(File.expand_path(path)))
        builder.instance_eval(File.read(path), path, 1)
        builder.config
      end
    end
  end
end
