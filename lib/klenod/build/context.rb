# frozen_string_literal: true

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

      def build(entrypoints:, output:)
        bundle = @graph.bundle(entrypoints: entrypoints)
        File.binwrite(output, Marshal.dump(bundle))
        bundle
      end

      def invalidate_paths(changed_paths, removed_paths: [])
        @graph.invalidate_paths(changed_paths, removed_paths: removed_paths)
      end

      def on_update(&block)
        @update_handlers << block
      end

      def emit_update(event)
        @update_handlers.each { |handler| handler.call(event) }
      end
    end
  end
end
