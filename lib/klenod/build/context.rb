# frozen_string_literal: true

require "fileutils"

require_relative "graph"
require_relative "loaded_module"
require_relative "plugins/ruby_plugin"
require_relative "plugins/intl_plugin"
require_relative "plugins/haml_plugin"
require_relative "plugins/css_plugin"
require_relative "plugins/image_plugin"
require_relative "plugins/data_plugin"
require_relative "plugins/router_plugin"
require_relative "config"

module Klenod
  module Build
    AssetWriteResult = Data.define(:written_paths, :removed_paths) do
      def empty?
        written_paths.empty? && removed_paths.empty?
      end
    end

    AppliedUpdate = Data.define(:event, :entry, :exports, :asset_write_result, :errors) do
      def success?
        errors.empty?
      end

      def failed?
        !success?
      end

      def entry_record
        entry&.record
      end

      def each_error(&block)
        return errors.each unless block

        errors.each(&block)
      end

      def error_messages
        errors.map { |module_id, error| "#{module_id}: #{error.class}: #{error.message}" }
      end

      def asset_files_changed?
        asset_write_result && !asset_write_result.empty?
      end

      def written_asset_paths
        asset_write_result&.written_paths || []
      end

      def removed_asset_paths
        asset_write_result&.removed_paths || []
      end
    end

    class Context
      DEFAULT_PLUGINS = [
        Plugins::RubyPlugin.new,
        Plugins::IntlPlugin.new,
        Plugins::HamlPlugin.new,
        Plugins::CssPlugin.new,
        Plugins::ImagePlugin.new,
        Plugins::JsonPlugin.new,
        Plugins::YamlPlugin.new,
        Plugins::TomlPlugin.new,
        Plugins::TextPlugin.new
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
            mode: mode,
            asset_generation_concurrency: asset_generation_concurrency
          )
      end

      attr_reader :graph, :mode

      def evaluate(specifier)
        @graph.load(specifier)
      end

      alias_method :load, :evaluate

      def collect(specifier)
        loaded(@graph.collect(specifier))
      end

      def entry(specifier)
        collect(specifier)
      end

      def loaded(record_or_module_id)
        return record_or_module_id if record_or_module_id.is_a?(LoadedModule)

        LoadedModule.new(self, record_or_module_id.respond_to?(:id) ? record_or_module_id.id : record_or_module_id)
      end

      def build(entrypoints:, output:, assets_dir: nil)
        bundle = @graph.bundle(entrypoints: entrypoints)
        wait_for_assets
        write_assets(assets_dir) if assets_dir
        FileUtils.mkdir_p(File.dirname(output))
        File.binwrite(output, Marshal.dump(bundle))
        bundle
      end

      def build_executable(entrypoints:, output:, assets_dir: nil)
        bundle = @graph.bundle(entrypoints: entrypoints)
        wait_for_assets
        write_assets(assets_dir) if assets_dir
        FileUtils.mkdir_p(File.dirname(output))
        File.binwrite(output, executable_bundle_source + Marshal.dump(bundle))
        FileUtils.chmod("+x", output)
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
        return record_or_module_id.exports if record_or_module_id.is_a?(LoadedModule)

        @graph.exports(record_or_module_id)
      end

      def evaluated?(record_or_module_id)
        record_or_module_id = record_or_module_id.id if record_or_module_id.is_a?(LoadedModule)
        @graph.evaluated?(record_or_module_id)
      end

      def module_id_for(record_or_module_id)
        return record_or_module_id.id if record_or_module_id.is_a?(LoadedModule)

        @graph.module_id_for(record_or_module_id)
      end

      def asset_bytes(output_path, assets_dir: nil)
        asset = asset(output_path)
        return asset.bytes unless assets_dir

        asset.wait
        File.binread(asset_disk_path(asset.output_path, Pathname.new(assets_dir)))
      end

      def assets_for(logical_name)
        @graph.assets_for(logical_name)
      end

      def assets_for_module(record_or_module_id, type: nil, content_type: nil, recursive: true)
        record_or_module_id = record_or_module_id.id if record_or_module_id.is_a?(LoadedModule)
        @graph.assets_for_module(record_or_module_id, type: type, content_type: content_type, recursive: recursive)
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

      def apply_update(event, entry:, assets_dir: nil)
        return AppliedUpdate.new(event, nil, nil, nil, event.result.errors.freeze) if event.result.errors.any?

        entry = loaded(entry)
        entry.record
        asset_write_result = assets_dir && write_asset_updates(event.asset_updates, assets_dir: assets_dir)

        AppliedUpdate.new(
          event,
          entry,
          evaluated?(entry) ? entry.exports : nil,
          asset_write_result,
          [].freeze
        )
      end

      def on_update(&block)
        @update_handlers << block
      end

      def emit_update(event)
        @update_handlers.each { |handler| handler.call(event) }
      end

      private

      def executable_bundle_source
        <<~RUBY.b
          #!/usr/bin/env ruby
          # encoding: ASCII-8BIT
          # frozen_string_literal: true

          require "klenod/runtime"

          Klenod::Runtime.load_executable_bundle(__FILE__).load_entrypoints

          __END__
        RUBY
      end

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
