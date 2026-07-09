# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../runtime"
require_relative "context"

class Klenod::Build::Context::Test < Minitest::Test
  FIXTURE_APP_DIR = File.expand_path("__test__/fixture_app", __dir__)

  module TestFramework
    class Component
    end

    module H
      def self.[](tag, *children, **props)
        props = props.compact
        return tag.new(**props, children: children).render if tag.respond_to?(:new)

        props.empty? ? [tag, *children] : [tag, *children, props]
      end
    end
  end

  class DelayedLoadPlugin < Klenod::Build::Plugin
    def initialize(events)
      @events = events
    end

    def load(module_id, _context)
      return nil unless module_id.path.start_with?("deps/")

      @events << [:start, module_id.path]
      sleep(0.01)
      @events << [:finish, module_id.path]

      "VALUE = #{module_id.path.inspect}\n"
    end
  end

  class CountingLoadPlugin < Klenod::Build::Plugin
    def initialize(events)
      @events = events
    end

    def load(module_id, context)
      return nil unless module_id.extname == ".rb"

      @events << [:start, module_id.path]
      sleep(0.01) if module_id.path == "shared.rb"
      source = context.absolute_path(module_id).binread
      @events << [:finish, module_id.path]
      source
    end
  end

  class DelayedTransformPlugin < Klenod::Build::Plugin
    def initialize(events)
      @events = events
    end

    def transform(module_id, code, _context)
      return Klenod::Build::TransformResult.identity(code) unless module_id.path.start_with?("deps/")

      @events << [:start, module_id.path]
      sleep(0.01)
      @events << [:finish, module_id.path]
      Klenod::Build::TransformResult.identity("VALUE = #{module_id.path.inspect}\n")
    end
  end

  def test_loads_entrypoint_and_dependencies_lazily
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write("#{dir}/pages/page.rb", "Dep = import(\"../dep\")\nVALUE = Dep::VALUE + 1\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("pages/page")
      mod = context.graph.mods.fetch(record.id)

      assert_equal(42, mod.const_get(:Exports)::VALUE)
      assert_equal(2, context.graph.records.length)
    end
  end

  def test_loads_sibling_dependencies_with_async
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/deps")
      File.write("#{dir}/deps/a.rb", "")
      File.write("#{dir}/deps/b.rb", "")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          A = import("deps/a.rb")
          B = import("deps/b.rb")
          VALUES = [A::VALUE, B::VALUE]
        RUBY
      )
      events = []
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin.new,
            DelayedLoadPlugin.new(events)
          ]
        )

      record = context.load("entry")
      values = context.graph.mods.fetch(record.id).const_get(:Exports)::VALUES

      assert_equal(["deps/a.rb", "deps/b.rb"], values)
      assert_equal([[:start, "deps/a.rb"], [:start, "deps/b.rb"]], events.first(2))
      assert_equal([[:finish, "deps/a.rb"], [:finish, "deps/b.rb"]], events.last(2))
    end
  end

  def test_concurrent_diamond_dependencies_share_in_flight_module_load
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/deps")
      File.write("#{dir}/shared.rb", "VALUE = 41\n")
      File.write("#{dir}/deps/a.rb", "Shared = import(\"../shared\")\nVALUE = Shared::VALUE\n")
      File.write("#{dir}/deps/b.rb", "Shared = import(\"../shared\")\nVALUE = Shared::VALUE + 1\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          A = import("deps/a")
          B = import("deps/b")
          VALUES = [A::VALUE, B::VALUE]
        RUBY
      )
      events = []
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin.new,
            CountingLoadPlugin.new(events)
          ]
        )

      record = context.load("entry")
      values = context.graph.mods.fetch(record.id).const_get(:Exports)::VALUES

      assert_equal([41, 42], values)
      assert_equal(1, events.count { |event, path| event == :start && path == "shared.rb" })
      assert_equal(1, events.count { |event, path| event == :finish && path == "shared.rb" })
      assert_equal(4, context.graph.records.length)
    end
  end

  def test_sibling_dependency_transforms_overlap
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/deps")
      File.write("#{dir}/deps/a.rb", "")
      File.write("#{dir}/deps/b.rb", "")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          A = import("deps/a")
          B = import("deps/b")
          VALUES = [A::VALUE, B::VALUE]
        RUBY
      )
      events = []
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin.new,
            DelayedTransformPlugin.new(events)
          ]
        )

      record = context.load("entry")
      values = context.graph.mods.fetch(record.id).const_get(:Exports)::VALUES

      assert_equal(["deps/a.rb", "deps/b.rb"], values)
      assert_equal([[:start, "deps/a.rb"], [:start, "deps/b.rb"]], events.first(2))
      assert_equal([[:finish, "deps/a.rb"], [:finish, "deps/b.rb"]], events.last(2))
    end
  end

  def test_direct_eager_import_cycle_raises_useful_error
    Dir.mktmpdir do |dir|
      File.write("#{dir}/entry.rb", "SelfImport = import(\"entry\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      error = assert_raises(Klenod::Build::ImportCycleError) { context.load("entry") }

      assert_equal(
        [Klenod::Build::ModuleId.new("entry.rb", nil), Klenod::Build::ModuleId.new("entry.rb", nil)],
        error.cycle
      )
      assert_equal("Import cycle detected: entry.rb -> entry.rb", error.message)
    end
  end

  def test_indirect_eager_import_cycle_raises_useful_error
    Dir.mktmpdir do |dir|
      File.write("#{dir}/a.rb", "B = import(\"b\")\n")
      File.write("#{dir}/b.rb", "C = import(\"c\")\n")
      File.write("#{dir}/c.rb", "A = import(\"a\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      error = assert_raises(Klenod::Build::ImportCycleError) { context.load("a") }

      assert_equal(["a.rb", "b.rb", "c.rb", "a.rb"], error.cycle.map(&:to_s))
      assert_equal("Import cycle detected: a.rb -> b.rb -> c.rb -> a.rb", error.message)
    end
  end

  def test_lazy_import_cycle_does_not_fail_initial_load
    Dir.mktmpdir do |dir|
      File.write(
        "#{dir}/a.rb",
        <<~RUBY
          B = lazy_import("b")

          def self.value
            B.call::VALUE + 1
          end
        RUBY
      )
      File.write("#{dir}/b.rb", "A = import(\"a\")\nVALUE = 41\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("a")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      refute(exports::B.loaded?)
      assert_equal(42, exports.value)
    end
  end

  def test_lazy_import_defers_loading_until_called
    Dir.mktmpdir do |dir|
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Dep = lazy_import("dep")

          def self.value
            Dep.call::VALUE + 1
          end
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      refute(context.graph.records.key?(Klenod::Build::ModuleId.new("dep.rb", nil)))
      refute(exports::Dep.loaded?)

      assert_equal(42, exports.value)
      assert(context.graph.records.key?(Klenod::Build::ModuleId.new("dep.rb", nil)))
      assert(exports::Dep.loaded?)
    end
  end

  def test_lazy_import_caches_loaded_value
    Dir.mktmpdir do |dir|
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Dep = lazy_import("dep")

          def self.loaded_values
            [Dep.call, Dep.call]
          end
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("entry")
      first, second = context.graph.mods.fetch(record.id).const_get(:Exports).loaded_values

      assert_same(first, second)
    end
  end

  def test_invalidate_loaded_lazy_dependency_reevaluates_importer
    Dir.mktmpdir do |dir|
      dep_path = "#{dir}/dep.rb"
      File.write(dep_path, "VALUE = 41\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Dep = lazy_import("dep")

          def self.value
            Dep.call::VALUE + 1
          end
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      entry_record = context.load("entry")
      exports = context.graph.mods.fetch(entry_record.id).const_get(:Exports)

      assert_equal(42, exports.value)

      File.write(dep_path, "VALUE = 99\n")
      result = context.invalidate_paths([dep_path])
      updated_exports = context.graph.mods.fetch(entry_record.id).const_get(:Exports)

      assert_equal(["dep.rb"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      refute(updated_exports::Dep.loaded?)
      assert_equal(100, updated_exports.value)
    end
  end

  def test_invalidate_unloaded_lazy_dependency_does_not_reevaluate_importer
    Dir.mktmpdir do |dir|
      dep_path = "#{dir}/dep.rb"
      File.write(dep_path, "VALUE = 41\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Dep = lazy_import("dep")

          def self.value
            Dep.call::VALUE + 1
          end
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      entry_record = context.load("entry")
      exports = context.graph.mods.fetch(entry_record.id).const_get(:Exports)

      File.write(dep_path, "VALUE = 99\n")
      result = context.invalidate_paths([dep_path])

      assert_equal([], result.reloaded_module_ids)
      assert_equal([], result.reevaluated_module_ids)
      assert_same(exports, context.graph.mods.fetch(entry_record.id).const_get(:Exports))
      assert_equal(100, exports.value)
    end
  end

  def test_build_writes_marshal_bundle
    Dir.mktmpdir do |dir|
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write("#{dir}/entry.rb", "Dep = import(\"dep\")\nVALUE = Dep::VALUE + 1\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      mod = loaded.load("entry")

      assert_equal(bundle.entrypoints, loaded.entrypoints)
      assert_equal(2, loaded.modules.length)
      assert_equal(42, mod.const_get(:Exports)::VALUE)
    end
  end

  def test_build_bundle_includes_lazy_imported_modules
    Dir.mktmpdir do |dir|
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Dep = lazy_import("dep")

          def self.value
            Dep.call::VALUE + 1
          end
        RUBY
      )
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      exports = loaded.load("entry").const_get(:Exports)

      assert_equal(2, bundle.modules.length)
      assert_raises(KeyError) { loaded.mod("dep.rb") }
      refute(exports::Dep.loaded?)
      assert_equal(42, exports.value)
      assert(exports::Dep.loaded?)
    end
  end

  def test_build_bundle_round_trips_haml_css_intl_and_image_assets
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/logo.png", png_bytes(width: 2, height: 3))
      File.write("#{dir}/pages/page.css", "main { color: red; }\n.hero { display: block; }\n")
      File.write("#{dir}/pages/page.intl.en-US.toml", "title = \"Hello bundle\"\n")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def initialize(image:)
              @image = image
            end

          %main
            %h1= Translations.fetch("en-US").fetch("title")
            %img.hero{ src: @image.src, width: @image.width, height: @image.height, alt: "Logo" }
        HAML
      )
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Page = import("pages/page.haml")
          Logo = import("images/logo.png")

          def self.call(context)
            [Page.new(image: Logo).render, context.assets_for("pages/page.css").map(&:output_path), Logo.src]
          end
        RUBY
      )
      output = "#{dir}/dist/klenod.bundle"
      assets_dir = "#{dir}/dist/public"
      plugins = default_plugins_with(
        Klenod::Build::Plugins::HamlPlugin.new(
          component_base_class: "#{self.class.name}::TestFramework::Component",
          factory: "#{self.class.name}::TestFramework::H"
        )
      )

      context = Klenod::Build::Context.new(source_dir: dir, plugins: plugins)
      bundle = context.build(entrypoints: ["entry"], output: output, assets_dir: assets_dir)
      loaded = Klenod::Runtime.load_bundle(output)
      rendered, css_asset_paths, image_src = loaded.load("entry").const_get(:Exports).call(loaded)
      heading = rendered.fetch(1)
      image = rendered.fetch(2)
      main_props = rendered.fetch(3)
      image_props = image.fetch(1)

      assert_equal(bundle.entrypoints, loaded.entrypoints)
      assert_equal([:main, heading, image, main_props], rendered)
      assert_equal([:h1, "Hello bundle"], heading)
      assert_match(/main/, main_props.fetch(:class))
      assert_equal(2, image_props.fetch(:width))
      assert_equal(3, image_props.fetch(:height))
      assert_match(/hero/, image_props.fetch(:class))
      assert_equal(css_asset_paths, loaded.assets_for("pages/page.css").map(&:output_path))
      assert_equal(image_src, loaded.assets_for("images/logo.png").fetch(0).output_path)
      loaded.each_asset do |asset|
        disk_path = File.join(assets_dir, asset.output_path.delete_prefix("/"))

        assert(File.exist?(disk_path), "Expected #{disk_path} to exist")
      end
    end
  end

  def test_fixture_app_covers_css_haml_assets_and_intl_files
    Dir.mktmpdir do |dir|
      output = "#{dir}/klenod.bundle"
      assets_dir = "#{dir}/public"
      plugins = default_plugins_with(
        Klenod::Build::Plugins::HamlPlugin.new(
          component_base_class: "#{self.class.name}::TestFramework::Component",
          factory: "#{self.class.name}::TestFramework::H"
        )
      )

      context = Klenod::Build::Context.new(source_dir: FIXTURE_APP_DIR, plugins: plugins)
      bundle = context.build(entrypoints: ["entry"], output: output, assets_dir: assets_dir)
      loaded = Klenod::Runtime.load_bundle(output)
      rendered, page_css_paths, card_css_paths, image_paths = loaded.load("entry").const_get(:Exports).render(loaded)
      heading = rendered.fetch(1)
      card = rendered.fetch(2)
      page_props = rendered.fetch(3)
      image = card.fetch(1)
      caption = card.fetch(2)
      card_props = card.fetch(3)

      assert_equal([:h1, "Fixture page"], heading)
      assert_equal([:figcaption, "Fixture caption"], caption)
      assert_match(/shell/, page_props.fetch(:class))
      assert_match(/main/, page_props.fetch(:class))
      assert_match(/card/, card_props.fetch(:class))
      assert_match(/figure/, card_props.fetch(:class))
      assert_match(/logo/, image.fetch(1).fetch(:class))
      assert_equal(bundle.assets.keys.sort, loaded.assets.keys.sort)
      assert_equal(page_css_paths, loaded.assets_for("pages/page.css").map(&:output_path))
      assert_equal(card_css_paths, loaded.assets_for("components/Card.css").map(&:output_path))
      assert_equal(image_paths, loaded.assets_for("images/logo.png").map(&:output_path))
      assert_equal(1, loaded.assets_for("styles/base.css").length)
      loaded.each_asset do |asset|
        disk_path = File.join(assets_dir, asset.output_path.delete_prefix("/"))

        assert(File.exist?(disk_path), "Expected #{disk_path} to exist")
      end
    end
  end

  def test_build_writes_css_assets_to_assets_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/home.css", ".title { color: red; }\n")
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/home.css\")\nTITLE = Styles.fetch(:title)\n")
      output = "#{dir}/dist/klenod.bundle"
      assets_dir = "#{dir}/dist/public"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output, assets_dir: assets_dir)
      asset_path, runtime_asset = bundle.assets.first
      asset = context.asset(asset_path)
      written_path = File.join(assets_dir, asset_path.delete_prefix("/"))

      assert_match(%r{\A/assets/styles_home_css\.[a-f0-9]{16}\.css\z}, asset_path)
      assert_equal(asset.bytes, File.binread(written_path))
      assert_equal("text/css", runtime_asset.content_type)
      assert_equal(context.asset(asset_path), context.assets.fetch(asset_path))
      assert_equal([asset.logical_name], context.assets_for("styles/home.css").map(&:logical_name))
      assert_includes(context.each_asset.to_a.map(&:output_path), asset_path)
    end
  end

  def test_asset_bytes_waits_for_generated_assets
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", generated_png_bytes(width: 4, height: 2))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Hero = import("images/hero.png")
          VARIANTS = Hero.variants
        RUBY
      )
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin.new,
            Klenod::Build::Plugins::ImagePlugin.new(widths: [2], formats: ["png"])
          ]
        )

      context.load("entry")
      variant_asset = context.assets_for("images/hero.png").find { |asset| asset.metadata[:type] == :image_variant }

      refute(variant_asset.ready?)
      assert_match(/\A.PNG/, context.asset_bytes(variant_asset.output_path))
      assert(variant_asset.ready?)
    end
  end

  def test_invalidate_paths_reports_asset_changes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      css_path = "#{dir}/styles/home.css"
      assets_dir = "#{dir}/public"
      File.write(css_path, ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.load("styles/home.css")
      old_asset = context.assets_for("styles/home.css").first
      old_asset_path = old_asset.output_path
      old_disk_path = File.join(assets_dir, old_asset_path.delete_prefix("/"))

      write_result = context.write_assets(assets_dir)

      assert_equal([old_disk_path], write_result.written_paths)
      assert_equal([], write_result.removed_paths)
      assert_equal(old_asset.bytes, File.binread(old_disk_path))

      File.write(css_path, ".title { color: blue; }\n")
      result = context.invalidate_paths([css_path])
      new_asset = context.assets_for("styles/home.css").first
      new_asset_path = new_asset.output_path
      new_disk_path = File.join(assets_dir, new_asset_path.delete_prefix("/"))

      assert_equal([new_asset_path], result.added_assets)
      assert_equal([old_asset_path], result.removed_assets)
      assert_equal([], result.changed_assets)
      assert_equal([new_asset_path], result.asset_changes.added)
      assert_equal([old_asset_path], result.asset_changes.removed)
      assert_equal([], result.asset_changes.changed)
      assert_equal([new_asset_path, old_asset_path], result.asset_changes.paths)
      refute(result.asset_changes.empty?)

      added_update = result.asset_updates.find(&:added?)
      removed_update = result.asset_updates.find(&:removed?)

      assert_equal(new_asset_path, added_update.output_path)
      assert_nil(added_update.previous_asset)
      assert_equal(new_asset, added_update.current_asset)
      assert_equal(old_asset_path, removed_update.output_path)
      assert_equal(old_asset, removed_update.previous_asset)
      assert_nil(removed_update.current_asset)

      update_write_result = context.write_asset_updates(result.asset_updates, assets_dir: assets_dir)

      assert_equal([new_disk_path], update_write_result.written_paths)
      assert_equal([old_disk_path], update_write_result.removed_paths)
      assert_equal(new_asset.bytes, File.binread(new_disk_path))
      refute(File.exist?(old_disk_path))
    end
  end

  def test_write_asset_updates_removes_failed_generated_asset_files
    Dir.mktmpdir do |dir|
      assets_dir = "#{dir}/public"
      stale_path = "/assets/stale.png"
      stale_disk_path = File.join(assets_dir, stale_path.delete_prefix("/"))
      FileUtils.mkdir_p(File.dirname(stale_disk_path))
      File.binwrite(stale_disk_path, "stale bytes")
      failed_asset =
        Klenod::Build::Asset.generated(
          "images/stale.png",
          "stale",
          stale_path,
          nil,
          "image/png",
          {}
        ) do
          raise "broken"
        end
      assert_raises(RuntimeError) { failed_asset.wait }
      update = Klenod::Build::AssetUpdate.new(stale_path, failed_asset, nil)

      context = Klenod::Build::Context.new(source_dir: dir)
      write_result = context.write_asset_updates([update], assets_dir: assets_dir)

      assert_equal([stale_disk_path], write_result.removed_paths)
      assert_equal([], write_result.written_paths)
      refute(File.exist?(stale_disk_path))
    end
  end

  def test_build_writes_image_assets_to_assets_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/logo.png", "png bytes")
      File.write(
        "#{dir}/styles/home.css",
        ".logo { background: url(\"../images/logo.png\"); }\n"
      )
      File.write("#{dir}/entry.rb", "Styles = import(\"styles/home.css\")\n")
      output = "#{dir}/dist/klenod.bundle"
      assets_dir = "#{dir}/dist/public"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output, assets_dir: assets_dir)
      image_asset =
        bundle.assets.values.find { |asset| asset.content_type == "image/png" }
      written_path = File.join(assets_dir, image_asset.output_path.delete_prefix("/"))

      assert_match(%r{\A/assets/logo\.[a-f0-9]{16}\.png\z}, image_asset.output_path)
      assert_equal("png bytes", File.binread(written_path))
    end
  end

  def test_invalidate_paths_reloads_changed_module_and_reevaluates_dependents
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      dep_path = "#{dir}/dep.rb"
      File.write(dep_path, "VALUE = 41\n")
      File.write("#{dir}/pages/page.rb", "Dep = import(\"../dep\")\nVALUE = Dep::VALUE + 1\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("pages/page")

      assert_equal(42, context.graph.mods.fetch(record.id).const_get(:Exports)::VALUE)

      File.write(dep_path, "VALUE = 99\n")

      result = context.invalidate_paths([dep_path])
      updated_record = context.graph.records.fetch(record.id)
      updated_mod = context.graph.mods.fetch(record.id)

      assert_equal(["dep.rb"], result.changed_module_ids.map(&:to_s))
      assert_equal(["dep.rb"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["pages/page.rb"], result.reevaluated_module_ids.map(&:to_s))
      assert_equal(100, updated_mod.const_get(:Exports)::VALUE)
      assert_equal(1, updated_record.version)
    end
  end

  def test_invalidate_paths_removes_deleted_module_and_reports_dependent_error
    Dir.mktmpdir do |dir|
      dep_path = "#{dir}/dep.rb"
      File.write(dep_path, "VALUE = 1\n")
      File.write("#{dir}/entry.rb", "Dep = import(\"dep\")\nVALUE = Dep::VALUE\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.load("entry")

      File.delete(dep_path)

      result = context.invalidate_paths([], removed_paths: [dep_path])

      assert_equal(["dep.rb"], result.removed_module_ids.map(&:to_s))
      assert_equal(["entry.rb"], result.errors.map { |module_id, _error| module_id.to_s })
    end
  end

  private

  def default_plugins_with(plugin)
    Klenod::Build::Context::DEFAULT_PLUGINS.map do |default_plugin|
      default_plugin.is_a?(Klenod::Build::Plugins::HamlPlugin) ? plugin : default_plugin
    end
  end

  def png_bytes(width:, height:)
    signature = "\x89PNG\r\n\x1a\n".b
    ihdr_data = [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")
    ihdr = [ihdr_data.bytesize].pack("N") + "IHDR" + ihdr_data + [0].pack("N")
    iend = [0].pack("N") + "IEND" + [0].pack("N")

    signature + ihdr + iend
  end

  def generated_png_bytes(width:, height:)
    image = Magick::Image.new(width, height) { |info| info.background_color = "red" }
    image.to_blob { |info| info.format = "PNG" }
  ensure
    image&.destroy!
  end
end
