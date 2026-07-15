# frozen_string_literal: true

require "async"
require "fileutils"

require_relative "graph"
require_relative "loaded_module"
require_relative "plugin"
require_relative "plugins"
require_relative "config"

module Klenod
  module Build
    AssetWriteResult = Data.define(:written_paths, :removed_paths, :skipped_paths) do
      def initialize(written_paths = nil, removed_paths = nil, skipped_paths = nil, **keywords)
        written_paths = keywords.fetch(:written_paths, written_paths)
        removed_paths = keywords.fetch(:removed_paths, removed_paths)
        skipped_paths = keywords.fetch(:skipped_paths, skipped_paths || [])

        super(
          written_paths: written_paths,
          removed_paths: removed_paths,
          skipped_paths: skipped_paths
        )
      end

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

      def skipped_asset_paths
        asset_write_result&.skipped_paths || []
      end
    end

    class Context
      class DefaultPlugins
        include Enumerable

        def each(&block)
          return enum_for(:each) unless block

          Context.default_plugins.each(&block)
        end

        def to_a
          Context.default_plugins
        end
      end

      DEFAULT_PLUGINS = DefaultPlugins.new.freeze

      def self.default_plugins
        [
          Plugins::RubyPlugin.new,
          Plugins::IntlPlugin.new,
          Plugins::HamlPlugin.new,
          Plugins::CssPlugin.new,
          Plugins::SvgPlugin.new,
          Plugins::ImagePlugin.new,
          Plugins::JsonPlugin.new,
          Plugins::YamlPlugin.new,
          Plugins::TomlPlugin.new,
          Plugins::TextPlugin.new
        ]
      end

      def initialize(
        source_dir:,
        plugins: DEFAULT_PLUGINS,
        mode: :development,
        asset_generation_concurrency: AssetGenerationQueue::DEFAULT_CONCURRENCY,
        asset_download_concurrency: AssetGenerationQueue::DEFAULT_DOWNLOAD_CONCURRENCY
      )
        @source_dir = source_dir
        plugins = plugins.to_a if plugins.equal?(DEFAULT_PLUGINS)
        @plugins = plugins
        @mode = mode
        @update_handlers = []
        @graph =
          Graph.new(
            source_dir: source_dir,
            plugins: plugins,
            mode: mode,
            asset_generation_concurrency: asset_generation_concurrency,
            asset_download_concurrency: asset_download_concurrency
          )
      end

      attr_reader :graph, :mode

      def evaluate(specifier)
        @graph.load(specifier)
      end

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
        assets_dir ? write_assets(assets_dir) : wait_for_assets
        FileUtils.mkdir_p(File.dirname(output))
        File.binwrite(output, Marshal.dump(bundle))
        bundle
      end

      def build_executable(entrypoints:, output:, assets_dir: nil)
        bundle = @graph.bundle(entrypoints: entrypoints)
        assets_dir ? write_assets(assets_dir) : wait_for_assets
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

        path = asset_disk_path(asset.output_path, Pathname.new(assets_dir))
        write_asset(asset, Pathname.new(assets_dir)) unless File.file?(path)
        File.binread(path)
      end

      def assets_for(logical_name)
        @graph.assets_for(logical_name)
      end

      def assets_for_module(record_or_module_id, type: nil, content_type: nil, recursive: true)
        @graph.assets_for_module(module_refs_for_assets(record_or_module_id), type: type, content_type: content_type, recursive: recursive)
      end

      def asset_references_for_module(record_or_module_id, type: nil, content_type: nil, recursive: true)
        @graph.asset_references_for_module(module_refs_for_assets(record_or_module_id), type: type, content_type: content_type, recursive: recursive)
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

      def write_assets(assets_dir, &block)
        assets_root = Pathname.new(assets_dir)
        results =
          with_async_task do |task|
            assets.each_value.map { |asset| task.async { write_asset(asset, assets_root, &block) } }.map(&:wait)
          end

        asset_write_result(results, removed_paths: [])
      end

      def write_asset_updates(asset_updates, assets_dir:, &block)
        assets_root = Pathname.new(assets_dir)
        removed_paths =
          asset_updates.filter_map do |update|
            remove_asset(update.output_path, assets_root) if update.removed?
          end
        written_paths =
          asset_updates.filter_map do |update|
            write_asset(update.current_asset, assets_root, &block) if update.current_asset
          end

        asset_write_result(written_paths, removed_paths: removed_paths)
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

      def write_asset(asset, assets_root, &block)
        output_path = asset_disk_path(asset.output_path, assets_root)
        status = asset.write_to(output_path) do |event, event_asset, event_path|
          block&.call(event, event_asset, event_path)
        end
        block&.call(status, asset, output_path.to_s)

        [status, output_path.to_s]
      end

      def asset_write_result(results, removed_paths:)
        written_paths = []
        skipped_paths = []

        results.each do |status, path|
          case status
          when :written then written_paths << path
          when :skipped then skipped_paths << path
          else raise ArgumentError, "unknown asset write status: #{status.inspect}"
          end
        end

        AssetWriteResult.new(
          written_paths: written_paths.freeze,
          removed_paths: removed_paths.freeze,
          skipped_paths: skipped_paths.freeze
        )
      end

      def remove_asset(output_path, assets_root)
        path = asset_disk_path(output_path, assets_root)

        FileUtils.rm_f(path)
        path.to_s
      end

      def with_async_task(&block)
        task = current_async_task
        return block.call(task) if task

        with_experimental_warnings_suppressed do
          Async(&block).wait
        end
      end

      def current_async_task
        Async::Task.current
      rescue RuntimeError
        nil
      end

      def with_experimental_warnings_suppressed
        enabled = Warning[:experimental]
        Warning[:experimental] = false
        yield
      ensure
        Warning[:experimental] = enabled
      end

      def asset_disk_path(output_path, assets_root)
        assets_root.join(output_path.delete_prefix("/"))
      end

      def module_refs_for_assets(record_or_module_id)
        if record_or_module_id.is_a?(Array)
          record_or_module_id.map { |module_ref| module_ref.is_a?(LoadedModule) ? module_ref.id : module_ref }
        elsif record_or_module_id.is_a?(LoadedModule)
          record_or_module_id.id
        else
          record_or_module_id
        end
      end
    end
  end
end
