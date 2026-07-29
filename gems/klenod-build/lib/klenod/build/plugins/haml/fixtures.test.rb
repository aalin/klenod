# frozen_string_literal: true

require_relative "../haml_test_support"

class Klenod::Build::Plugins::HamlPlugin::FixturesTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  Dir.glob("#{HAML_FIXTURE_DIR}/*.haml").sort.each do |path|
    fixture_path = path
    basename = File.basename(fixture_path, ".haml")
    test_name = "test_haml_fixture_#{basename.gsub(/[^A-Za-z0-9_]/, "_")}"

    define_method(test_name) do
      expected_path = fixture_path.delete_suffix(".haml") + ".rb"
      actual = transform_haml_fixture(fixture_path)

      unless File.exist?(expected_path)
        warn("Generated #{expected_path}")
        File.write(expected_path, actual)
      end

      assert_equal(File.read(expected_path), actual, "Expected #{expected_path} to match #{fixture_path}")
    end

    cached_expected_path = fixture_path.delete_suffix(".haml") + ".cached.rb"
    if File.exist?(cached_expected_path)
      define_method("#{test_name}_with_static_subtree_cache") do
        actual = transform_haml_fixture(fixture_path, cache_static_subtrees: true)

        assert_equal(File.read(cached_expected_path), actual, "Expected #{cached_expected_path} to match #{fixture_path}")
      end
    end
  end
end
