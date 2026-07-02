# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "dependency"
require_relative "module_id"
require_relative "resolver"

class Klenod::Build::Resolver::Test < Minitest::Test
  Dependency = Klenod::Build::Dependency
  ModuleId = Klenod::Build::ModuleId
  Resolver = Klenod::Build::Resolver

  def test_resolves_relative_and_absolute_imports
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.rb", "")
      File.write("#{dir}/shared.rb", "")

      resolver = Resolver.new(source_dir: dir)
      importer = ModuleId.new("pages/page.rb", nil)

      relative =
        resolver.resolve(
          Dependency.create(specifier: "../shared", importer_id: importer, kind: :ruby_import)
        )
      absolute =
        resolver.resolve(
          Dependency.create(specifier: "shared", importer_id: importer, kind: :ruby_import)
        )

      assert_equal("shared.rb", relative.module_id.path)
      assert_equal("shared.rb", absolute.module_id.path)
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

      assert_equal("image.png?width=100", resolved.module_id.to_s)
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
    end
  end
end
