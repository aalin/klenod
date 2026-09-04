# frozen_string_literal: true

require "minitest/autorun"

require_relative "klenod"

class Klenod::MetaGemTest < Minitest::Test
  def test_require_klenod_loads_public_package_surface
    assert_equal(File.read(File.expand_path("../../../KLENOD_VERSION", __dir__)).strip, Klenod::VERSION)
    assert_equal(Klenod::VERSION, Klenod::Runtime::VERSION)
    assert_equal(Klenod::VERSION, Klenod::Build::VERSION)
    assert(defined?(Klenod::Runtime))
    assert(defined?(Klenod::Build))
    assert(defined?(Klenod::Test))
    refute(defined?(Klenod::Rack))
    assert(defined?(Klenod::Build::Watcher))
  end

  def test_require_klenod_does_not_restore_removed_namespaces
    refute(defined?(Klenod::HTTP))
    refute(defined?(Klenod::Dev))
  end

  def test_meta_gemspec_depends_on_runtime_build_and_test_packages
    spec = Gem::Specification.load(File.expand_path("../klenod.gemspec", __dir__))
    dependency_names = spec.dependencies.map(&:name)
    dependency_requirements = spec.dependencies.to_h { |dependency| [dependency.name, dependency.requirement.to_s] }

    assert_includes(dependency_names, "klenod-build")
    assert_includes(dependency_names, "klenod-runtime")
    assert_includes(dependency_names, "klenod-test")
    refute_includes(dependency_names, "klenod-rack")
    assert_equal("= #{Klenod::VERSION}", dependency_requirements.fetch("klenod-build"))
    assert_equal("= #{Klenod::VERSION}", dependency_requirements.fetch("klenod-runtime"))
    assert_equal("= #{Klenod::VERSION}", dependency_requirements.fetch("klenod-test"))
    assert_includes(spec.files, "lib/klenod/cli.rb")
    assert_includes(spec.files, "lib/klenod/cli/application.rb")
    assert_includes(spec.files, "exe/klenod")
  end

  def test_split_gem_versions_match_root_version
    root_version = File.read(File.expand_path("../../../KLENOD_VERSION", __dir__)).strip
    specs = [
      Gem::Specification.load(File.expand_path("../klenod.gemspec", __dir__)),
      Gem::Specification.load(File.expand_path("../../klenod-build/klenod-build.gemspec", __dir__)),
      Gem::Specification.load(File.expand_path("../../klenod-test/klenod-test.gemspec", __dir__)),
      Gem::Specification.load(File.expand_path("../../klenod-rack/klenod-rack.gemspec", __dir__)),
      Gem::Specification.load(File.expand_path("../../klenod-runtime/klenod-runtime.gemspec", __dir__))
    ]

    assert_equal(root_version, Klenod::VERSION)
    assert_equal(root_version, Klenod::Build::VERSION)
    assert_equal(root_version, Klenod::Runtime::VERSION)
    assert_equal([root_version], specs.map { |spec| spec.version.to_s }.uniq)
    assert_equal([">= 4.0"], specs.map { |spec| spec.required_ruby_version.to_s }.uniq)

    specs.flat_map(&:dependencies).each do |dependency|
      next unless dependency.name.start_with?("klenod")

      assert_equal("= #{root_version}", dependency.requirement.to_s)
    end
  end
end
