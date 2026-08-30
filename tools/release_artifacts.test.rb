# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "release_artifacts"

class ReleaseArtifactsTest < Minitest::Test
  VERSION = "1.2.3"
  FakeClient = Data.define(:shas) do
    def sha_for(*identity)
      shas[identity]
    end

    def wait_for(*)
      raise "wait_for should not be called for an existing artifact"
    end
  end

  def test_matrices_cover_the_expected_artifacts
    assert_equal ReleaseArtifacts::SOURCE_GEMS, ReleaseArtifacts.source_matrix.map { it.fetch(:name) }
    assert_equal(
      ReleaseArtifacts::NATIVE_GEMS.length * ReleaseArtifacts::NATIVE_PLATFORMS.length,
      ReleaseArtifacts.native_matrix.length
    )
    assert_equal 14, ReleaseArtifacts.expected_identities(VERSION).length
  end

  def test_verify_accepts_a_complete_release_and_writes_checksums
    Dir.mktmpdir do |directory|
      capture_io { build_release(directory) }
      manifest = File.join(directory, "SHA256SUMS")

      artifacts = ReleaseArtifacts.verify(directory, version: VERSION, manifest:)

      assert_equal 14, artifacts.length
      assert_equal 14, File.readlines(manifest).length
    end
  end

  def test_verify_rejects_a_missing_platform
    Dir.mktmpdir do |directory|
      capture_io { build_release(directory) }
      File.delete(File.join(directory, "klenod-plugin-css-#{VERSION}-arm64-darwin.gem"))

      error = assert_raises(RuntimeError) do
        ReleaseArtifacts.verify(directory, version: VERSION)
      end

      assert_includes error.message, "missing artifacts"
      assert_includes error.message, "klenod-plugin-css-#{VERSION}-arm64-darwin"
    end
  end

  def test_publish_skips_artifacts_already_published_with_the_same_checksum
    Dir.mktmpdir do |directory|
      capture_io { build_release(directory) }
      artifacts = ReleaseArtifacts.verify(directory, version: VERSION)
      client = FakeClient.new(artifacts.to_h { [it.identity, it.sha256] })

      output, = capture_io do
        ReleaseArtifacts.publish(directory, version: VERSION, client:)
      end

      assert_includes output, "Already published klenod-runtime-#{VERSION}"
      assert_includes output, "Already published klenod-plugin-css-#{VERSION}-arm64-darwin"
    end
  end

  def test_publish_rejects_an_existing_artifact_with_a_different_checksum
    Dir.mktmpdir do |directory|
      capture_io { build_release(directory) }
      artifacts = ReleaseArtifacts.verify(directory, version: VERSION)
      client = FakeClient.new(artifacts.to_h { [it.identity, it.sha256] }.merge(artifacts.first.identity => "different"))

      error = nil
      capture_io do
        error = assert_raises(RuntimeError) do
          ReleaseArtifacts.publish(directory, version: VERSION, client:)
        end
      end

      assert_includes error.message, "different SHA-256"
    end
  end

  private

  def build_release(directory)
    ReleaseArtifacts.expected_identities(VERSION).each do |name, version, platform|
      build_gem(directory, name:, version:, platform:)
    end
  end

  def build_gem(directory, name:, version:, platform:)
    spec = Gem::Specification.new do |gem|
      gem.name = name
      gem.version = version
      gem.summary = "Release test"
      gem.authors = ["Klenod"]
      gem.files = ["lib/#{name}.rb"]
      gem.platform = platform
      gem.add_dependency("klenod-build", "= #{version}") if name.start_with?("klenod-plugin-")
    end

    Dir.mktmpdir do |build_directory|
      Dir.chdir(build_directory) do
        FileUtils.mkdir_p("lib")
        File.write("lib/#{name}.rb", "# test\n")
        Gem::Package.build(spec, true)
        FileUtils.mv(spec.file_name, directory)
      end
    end
  end
end
