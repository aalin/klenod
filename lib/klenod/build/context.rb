# frozen_string_literal: true

require "fileutils"
require "pathname"

require_relative "graph"
require_relative "plugins/ruby_plugin"
require_relative "plugins/intl_plugin"
require_relative "plugins/haml_plugin"
require_relative "plugins/css_plugin"
require_relative "plugins/image_plugin"

module Klenod
  module Build
    class Context
      DEFAULT_PLUGINS = [
        Plugins::RubyPlugin.new,
        Plugins::IntlPlugin.new,
        Plugins::HamlPlugin.new,
        Plugins::CssPlugin.new,
        Plugins::ImagePlugin.new
      ].freeze

      def initialize(source_dir:, plugins: DEFAULT_PLUGINS, mode: :development)
        @source_dir = source_dir
        @plugins = plugins
        @mode = mode
        @update_handlers = []
        @graph = Graph.new(source_dir: source_dir, plugins: plugins)
      end

      attr_reader :graph, :mode

      def load(specifier)
        @graph.load(specifier)
      end

      def build(entrypoints:, output:, assets_dir: nil)
        bundle = @graph.bundle(entrypoints: entrypoints)
        write_assets(bundle, assets_dir) if assets_dir
        FileUtils.mkdir_p(File.dirname(output))
        File.binwrite(output, Marshal.dump(bundle))
        bundle
      end

      def invalidate_paths(changed_paths, removed_paths: [])
        @graph.invalidate_paths(changed_paths, removed_paths: removed_paths)
      end

      def assets
        @graph.assets
      end

      def asset(output_path)
        @graph.asset(output_path)
      end

      def assets_for(logical_name)
        @graph.assets_for(logical_name)
      end

      def each_asset(&block)
        @graph.each_asset(&block)
      end

      def on_update(&block)
        @update_handlers << block
      end

      def emit_update(event)
        @update_handlers.each { |handler| handler.call(event) }
      end

      private

      def write_assets(bundle, assets_dir)
        assets_root = Pathname.new(assets_dir)

        bundle.assets.each_value do |asset|
          relative_path = asset.output_path.delete_prefix("/")
          output_path = assets_root.join(relative_path)

          FileUtils.mkdir_p(output_path.dirname)
          File.binwrite(output_path, asset.bytes)
        end
      end
    end
  end
end
