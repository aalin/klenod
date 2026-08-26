# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "filesystem_resolver"

class Klenod::Build::FilesystemResolver::Test < Minitest::Test
  Resolver = Klenod::Build::FilesystemResolver
  ResolveError = Klenod::Build::ResolveError

  def test_resolves_an_exact_path
    with_files("components/PageHeader.haml") do |dir|
      path = Resolver.new(root: dir).resolve("components/PageHeader.haml")

      assert_equal(File.join(dir, "components/PageHeader.haml"), path.to_s)
    end
  end

  def test_rejects_incorrect_file_case
    with_files("components/PageHeader.haml") do |dir|
      error = assert_raises(ResolveError) do
        Resolver.new(root: dir).resolve("components/pageheader.haml")
      end

      assert_equal(
        'Incorrect case for "components/pageheader.haml". Use "components/PageHeader.haml".',
        error.message
      )
    end
  end

  def test_rejects_incorrect_directory_case
    with_files("components/PageHeader.haml") do |dir|
      error = assert_raises(ResolveError) do
        Resolver.new(root: dir).resolve("Components/PageHeader.haml")
      end

      assert_equal(
        'Incorrect case for "Components/PageHeader.haml". Use "components/PageHeader.haml".',
        error.message
      )
    end
  end

  def test_checks_case_for_extensionless_paths
    with_files("components/PageHeader.haml") do |dir|
      error = assert_raises(ResolveError) do
        Resolver.new(root: dir, extensions: [".rb", ".haml"]).resolve("components/pageheader")
      end

      assert_equal(
        'Incorrect case for "components/pageheader". Use "components/PageHeader.haml".',
        error.message
      )
    end
  end

  def test_does_not_infer_an_extension_preference_from_the_importer
    with_files("components/PageHeader.rb", "components/PageHeader.haml") do |dir|
      error = assert_raises(ResolveError) do
        Resolver.new(root: dir, extensions: [".rb", ".haml"]).resolve("components/PageHeder")
      end

      assert_includes(error.message, "components/PageHeader.rb")
      assert_includes(error.message, "components/PageHeader.haml")
    end
  end

  def test_limits_spelling_corrections_to_three
    with_files(
      "components/PageHeader.haml",
      "components/PageHeaders.haml",
      "components/PageHeading.haml",
      "components/PageHeader.rb"
    ) do |dir|
      resolver = Resolver.new(root: dir, extensions: [".rb", ".haml"])
      error = assert_raises(ResolveError) { resolver.resolve("components/PageHeder") }
      suggestions = error.message.split("Did you mean ", 2).fetch(1)

      assert_equal(3, suggestions.scan(%r{components/}).length)
    end
  end

  def test_adds_a_namespace_prefix_to_errors
    with_files("components/PageHeader.haml") do |dir|
      resolver = Resolver.new(root: dir, path_prefix: "gem://klenod-ui/")
      error = assert_raises(ResolveError) { resolver.resolve("components/PageHeder.haml") }

      assert_includes(error.message, "gem://klenod-ui/components/PageHeder.haml")
      assert_includes(error.message, "gem://klenod-ui/components/PageHeader.haml")
      assert_equal("gem://klenod-ui/components/PageHeder.haml", error.unresolved_path)
    end
  end

  def test_rejects_paths_outside_the_root
    Dir.mktmpdir do |dir|
      error = assert_raises(ResolveError) { Resolver.new(root: dir).resolve("../outside.rb") }

      assert_includes(error.message, "escapes root")
    end
  end

  private

  def with_files(*paths)
    Dir.mktmpdir do |dir|
      paths.each do |path|
        absolute_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        File.write(absolute_path, "")
      end

      yield dir
    end
  end
end
