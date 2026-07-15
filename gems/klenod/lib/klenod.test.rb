# frozen_string_literal: true

require "minitest/autorun"

require_relative "klenod"

class Klenod::MetaGemTest < Minitest::Test
  def test_require_klenod_loads_public_package_surface
    assert_equal("0.1.0", Klenod::VERSION)
    assert(defined?(Klenod::Runtime))
    assert(defined?(Klenod::Build))
    assert(defined?(Klenod::Rack))
    assert(defined?(Klenod::Build::Watcher))
  end

  def test_require_klenod_does_not_restore_removed_namespaces
    refute(defined?(Klenod::HTTP))
    refute(defined?(Klenod::CLI))
    refute(defined?(Klenod::Dev))
  end

  def test_meta_gemspec_depends_on_build_and_rack_packages
    spec = Gem::Specification.load(File.expand_path("../klenod.gemspec", __dir__))
    dependency_names = spec.dependencies.map(&:name)

    assert_includes(dependency_names, "klenod-build")
    assert_includes(dependency_names, "klenod-rack")
    refute_includes(dependency_names, "klenod-runtime")
  end
end
