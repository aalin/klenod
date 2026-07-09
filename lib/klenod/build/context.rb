# frozen_string_literal: true

require "fileutils"
require "pathname"

require_relative "graph"
require_relative "page_discovery"
require_relative "plugins/ruby_plugin"
require_relative "plugins/intl_plugin"
require_relative "plugins/haml_plugin"
require_relative "plugins/css_plugin"
require_relative "plugins/image_plugin"

module Klenod
  module Build
    AssetWriteResult = Data.define(:written_paths, :removed_paths) do
      def empty?
        written_paths.empty? && removed_paths.empty?
      end
    end

    class Context
      DEFAULT_PLUGINS = [
        Plugins::RubyPlugin.new,
        Plugins::IntlPlugin.new,
        Plugins::HamlPlugin.new,
        Plugins::CssPlugin.new,
        Plugins::ImagePlugin.new
      ].freeze

      def initialize(
        source_dir:,
        plugins: DEFAULT_PLUGINS,
        mode: :development,
        asset_generation_concurrency: AssetGenerationQueue::DEFAULT_CONCURRENCY
      )
        @source_dir = source_dir
        @plugins = plugins
        @mode = mode
        @update_handlers = []
        @graph =
          Graph.new(
            source_dir: source_dir,
            plugins: plugins,
            asset_generation_concurrency: asset_generation_concurrency
          )
      end

      attr_reader :graph, :mode

      def load(specifier)
        @graph.load(specifier)
      end

      def build(entrypoints:, output:, assets_dir: nil)
        bundle = @graph.bundle(entrypoints: entrypoints)
        wait_for_assets
        write_assets(assets_dir) if assets_dir
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

      def exports(record_or_module_id)
        @graph.exports(record_or_module_id)
      end

      def asset_bytes(output_path)
        asset(output_path).bytes
      end

      def assets_for(logical_name)
        @graph.assets_for(logical_name)
      end

      def assets_for_module(record_or_module_id, type: nil, content_type: nil)
        @graph.assets_for_module(record_or_module_id, type: type, content_type: content_type)
      end

      def each_asset(&block)
        @graph.each_asset(&block)
      end

      def wait_for_assets
        @graph.wait_for_assets
      end

      def asset_generation_queue
        @graph.asset_generation_queue
      end

      def page_routes(pages_dir: "pages")
        route_manifest(pages_dir: pages_dir).routes
      end

      def route_manifest(pages_dir: "pages")
        PageDiscovery.new(source_dir: @source_dir, pages_dir: pages_dir).call
      end

      def write_assets(assets_dir)
        assets_root = Pathname.new(assets_dir)
        written_paths = assets.each_value.map { |asset| write_asset(asset, assets_root) }

        AssetWriteResult.new(written_paths.freeze, [].freeze)
      end

      def write_asset_updates(asset_updates, assets_dir:)
        assets_root = Pathname.new(assets_dir)
        removed_paths =
          asset_updates.filter_map do |update|
            remove_asset(update.output_path, assets_root) if update.removed?
          end
        written_paths =
          asset_updates.filter_map do |update|
            write_asset(update.current_asset, assets_root) if update.current_asset
          end

        AssetWriteResult.new(written_paths.freeze, removed_paths.freeze)
      end

      def on_update(&block)
        @update_handlers << block
      end

      def emit_update(event)
        @update_handlers.each { |handler| handler.call(event) }
      end

      private

      def write_asset(asset, assets_root)
        output_path = asset_disk_path(asset.output_path, assets_root)

        FileUtils.mkdir_p(output_path.dirname)
        File.binwrite(output_path, asset.bytes)
        output_path.to_s
      end

      def remove_asset(output_path, assets_root)
        path = asset_disk_path(output_path, assets_root)

        FileUtils.rm_f(path)
        path.to_s
      end

      def asset_disk_path(output_path, assets_root)
        assets_root.join(output_path.delete_prefix("/"))
      end
    end
  end
end
