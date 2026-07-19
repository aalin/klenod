# frozen_string_literal: true

require "digest"
require "minitest/autorun"
require "tmpdir"

require "bundler/setup"
require "klenod"
require_relative "lib/performance_case"

class KlenodPerformanceExampleTest < Minitest::Test
  def test_generated_case_is_deterministic_and_buildable
    Dir.mktmpdir do |dir|
      generator = KlenodPerformance::Generator.new(root_dir: dir)
      case_definition = KlenodPerformance::CaseDefinition.new(name: "tiny", component_count: 12, route_count: 3)

      first_case_dir = generator.generate(case_definition)
      first_digest = digest_case(first_case_dir)
      second_case_dir = generator.generate(case_definition)
      second_digest = digest_case(second_case_dir)

      assert_equal(first_digest, second_digest)
      assert_path_exists(File.join(second_case_dir, "src/components/cluster-00/group-00/Component0001.haml"))
      assert_path_exists(File.join(second_case_dir, "src/components/cluster-00/group-00/Component0001.css"))
      assert_path_exists(File.join(second_case_dir, "src/pages/bench/section-00/group-00/route-001/page.haml"))

      config = Klenod::Build::ConfigLoader.load(File.join(second_case_dir, "klenod.config.rb"))
      context = config.context
      bundle = context.build(entrypoints: config.entrypoints, output: config.output_path, assets_dir: config.assets_path)

      assert_operator(bundle.modules.length, :>, 0)
      assert_operator(bundle.assets.length, :>, 0)
      assert_path_exists(config.output_path)
    end
  end

  private

  def digest_case(case_dir)
    digest = Digest::SHA256.new
    Dir.glob(File.join(case_dir, "**", "*")).sort.each do |path|
      next if File.directory?(path)

      relative_path = path.delete_prefix("#{case_dir}/")
      digest.update(relative_path)
      digest.update("\0")
      digest.update(File.binread(path))
      digest.update("\0")
    end
    digest.hexdigest
  end
end
