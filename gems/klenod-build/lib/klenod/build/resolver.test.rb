# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "dependency"
require_relative "module_id"
require_relative "profiler"
require_relative "resolver"

class Klenod::Build::Resolver::Test < Minitest::Test
  Dependency = Klenod::Build::Dependency
  ModuleId = Klenod::Build::ModuleId
  Resolver = Klenod::Build::Resolver

  def test_resolves_relative_and_absolute_imports
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.rb", "")
      File.write("#{dir}/pages/shared.rb", "")
      File.write("#{dir}/shared.rb", "")

      resolver = Resolver.new(source_dir: dir)
      importer = ModuleId.new("pages/page.rb", nil)

      relative =
        resolver.resolve(
          Dependency.create(specifier: "../shared", importer_id: importer, kind: :ruby_import)
        )
      current_dir =
        resolver.resolve(
          Dependency.create(specifier: "./shared", importer_id: importer, kind: :ruby_import)
        )
      absolute =
        resolver.resolve(
          Dependency.create(specifier: "shared", importer_id: importer, kind: :ruby_import)
        )
      explicit_root =
        resolver.resolve(
          Dependency.create(specifier: "/shared", importer_id: importer, kind: :ruby_import)
        )
      explicit_app =
        resolver.resolve(
          Dependency.create(specifier: "app:/shared", importer_id: importer, kind: :ruby_import)
        )

      assert_equal("shared.rb", relative.module_id.path)
      assert_equal("pages/shared.rb", current_dir.module_id.path)
      assert_equal("pages/shared.rb", absolute.module_id.path)
      assert_equal("shared.rb", explicit_root.module_id.path)
      assert_equal("shared.rb", explicit_app.module_id.path)
    end
  end

  def test_preserves_query
    Dir.mktmpdir do |dir|
      File.write("#{dir}/image.png", "")

      resolver = Resolver.new(source_dir: dir, extensions: [".png"])
      resolved =
        resolver.resolve(
          Dependency.create(specifier: "image?width=100", importer_id: nil, kind: :asset_url)
        )

      assert_equal("app:/image.png?width=100", resolved.module_id.to_s)
    end
  end

  def test_resolves_extensionless_imports_by_extension_order
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.rb", "")
      File.write("#{dir}/pages/page.haml", "")

      resolver = Resolver.new(source_dir: dir)
      resolved =
        resolver.resolve(
          Dependency.create(specifier: "pages/page", importer_id: nil, kind: :entrypoint)
        )

      assert_equal("pages/page.rb", resolved.module_id.path)
    end
  end

  def test_clear_cache_recomputes_extensionless_resolution
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "")

      resolver = Resolver.new(source_dir: dir)
      dependency = Dependency.create(specifier: "pages/page", importer_id: nil, kind: :entrypoint)

      assert_equal("pages/page.haml", resolver.resolve(dependency).module_id.path)

      File.write("#{dir}/pages/page.rb", "")

      assert_equal("pages/page.haml", resolver.resolve(dependency).module_id.path)

      resolver.clear_cache

      assert_equal("pages/page.rb", resolver.resolve(dependency).module_id.path)
    end
  end

  def test_reports_resolver_cache_counts
    Dir.mktmpdir do |dir|
      File.write("#{dir}/page.rb", "")

      profiler = Klenod::Build::Profiler.new(enabled: true)
      resolver = Resolver.new(source_dir: dir, profiler: profiler)
      dependency = Dependency.create(specifier: "page", importer_id: nil, kind: :entrypoint)

      resolver.resolve(dependency)
      resolver.resolve(dependency)
      resolver.absolute_path(ModuleId.new("page.rb", nil))
      resolver.absolute_path(ModuleId.new("page.rb", nil))

      assert_equal(1, profiler.counts.fetch(:resolver_cache_miss))
      assert_equal(1, profiler.counts.fetch(:resolver_cache_hit))
      assert_equal(1, profiler.counts.fetch(:resolver_absolute_path_cache_miss))
      assert_equal(1, profiler.counts.fetch(:resolver_absolute_path_cache_hit))
    end
  end

  def test_skips_explicit_only_extensions_for_extensionless_imports
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/components")
      File.write("#{dir}/components/PageHeader.haml", "")
      File.write("#{dir}/components/PageHeader.css", "")

      resolver = Resolver.new(source_dir: dir)
      resolved =
        resolver.resolve(
          Dependency.create(specifier: "components/PageHeader", importer_id: nil, kind: :ruby_import)
        )

      assert_equal("components/PageHeader.haml", resolved.module_id.path)
    end
  end

  def test_resolves_explicit_css_imports
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/components")
      File.write("#{dir}/components/PageHeader.css", "")

      resolver = Resolver.new(source_dir: dir)
      resolved =
        resolver.resolve(
          Dependency.create(specifier: "components/PageHeader.css", importer_id: nil, kind: :ruby_import)
        )

      assert_equal("components/PageHeader.css", resolved.module_id.path)
    end
  end

  def test_rejects_source_dir_escape
    Dir.mktmpdir do |dir|
      resolver = Resolver.new(source_dir: dir)

      assert_raises(Klenod::Build::ResolveError) do
        resolver.resolve(
          Dependency.create(specifier: "../outside", importer_id: ModuleId.new("page.rb", nil), kind: :ruby_import)
        )
      end

      assert_raises(Klenod::Build::ResolveError) do
        resolver.resolve(
          Dependency.create(specifier: "/../outside", importer_id: ModuleId.new("page.rb", nil), kind: :ruby_import)
        )
      end
    end
  end
end
