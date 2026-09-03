# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "rubygems/package"
require "uri"

module ReleaseArtifacts
  SOURCE_GEMS = %w[
    klenod-runtime
    klenod-build
    klenod-test
    klenod-rack
    klenod-plugin-css
    klenod-plugin-javascript
    klenod
  ].freeze

  NATIVE_GEMS = {
    "klenod-plugin-css" => "gems/klenod-plugin-css",
    "klenod-plugin-javascript" => "gems/klenod-plugin-javascript"
  }.freeze

  NATIVE_PLATFORMS = %w[
    x86_64-linux-gnu
    aarch64-linux-gnu
    x86_64-darwin
    arm64-darwin
  ].freeze

  PUBLISH_ORDER = SOURCE_GEMS.each_with_index.to_h.freeze
  Artifact = Data.define(:path, :spec, :sha256) do
    def identity
      [spec.name, spec.version.to_s, spec.platform.to_s]
    end
  end

  module_function

  def source_matrix
    SOURCE_GEMS.map { |name| {name:, directory: "gems/#{name}"} }
  end

  def native_matrix
    NATIVE_GEMS.flat_map do |name, directory|
      NATIVE_PLATFORMS.map { |platform| {name:, directory:, platform:} }
    end
  end

  def expected_identities(version)
    SOURCE_GEMS.map { |name| [name, version, "ruby"] } +
      NATIVE_GEMS.keys.flat_map do |name|
        NATIVE_PLATFORMS.map { |platform| [name, version, platform] }
      end
  end

  def load_artifacts(directory)
    Dir[File.join(directory, "*.gem")].sort.map do |path|
      spec = Gem::Package.new(path).spec
      Artifact.new(path:, spec:, sha256: Digest::SHA256.file(path).hexdigest)
    end
  end

  def verify(directory, version:, manifest: nil)
    artifacts = load_artifacts(directory)
    actual = artifacts.map(&:identity)
    expected = expected_identities(version)
    duplicates = actual.tally.select { |_identity, count| count > 1 }.keys
    missing = expected - actual
    unexpected = actual - expected

    errors = []
    errors << "duplicate artifacts: #{format_identities(duplicates)}" unless duplicates.empty?
    errors << "missing artifacts: #{format_identities(missing)}" unless missing.empty?
    errors << "unexpected artifacts: #{format_identities(unexpected)}" unless unexpected.empty?

    artifacts.each do |artifact|
      expected_filename = "#{artifact.spec.full_name}.gem"
      errors << "#{artifact.path}: expected filename #{expected_filename}" unless File.basename(artifact.path) == expected_filename

      artifact.spec.dependencies.each do |dependency|
        next unless SOURCE_GEMS.include?(dependency.name)

        expected_requirement = Gem::Requirement.new("= #{version}")
        next if dependency.requirement == expected_requirement

        errors << "#{artifact.path}: #{dependency.name} must require #{expected_requirement}, got #{dependency.requirement}"
      end
    end

    raise errors.join("\n") unless errors.empty?

    write_manifest(artifacts, manifest) if manifest
    artifacts
  end

  def write_manifest(artifacts, path)
    lines = artifacts.sort_by { File.basename(it.path) }.map do |artifact|
      "#{artifact.sha256}  #{File.basename(artifact.path)}"
    end
    File.write(path, "#{lines.join("\n")}\n")
  end

  def publish(directory, version:, client: RubyGemsClient.new)
    artifacts = verify(directory, version:)
    artifacts.sort_by { |artifact| publish_sort_key(artifact) }.each do |artifact|
      remote_sha = client.sha_for(*artifact.identity)

      if remote_sha
        raise "#{identity_name(artifact.identity)} already exists with a different SHA-256" unless remote_sha == artifact.sha256

        puts "Already published #{identity_name(artifact.identity)}"
        next
      end

      puts "Publishing #{File.basename(artifact.path)}"
      raise "gem push failed for #{artifact.path}" unless system(Gem.ruby, "-S", "gem", "push", artifact.path)

      client.wait_for(artifact.identity, artifact.sha256)
    end
  end

  def publish_sort_key(artifact)
    [PUBLISH_ORDER.fetch(artifact.spec.name), (artifact.spec.platform.to_s == "ruby") ? 0 : 1, artifact.spec.platform.to_s]
  end

  def format_identities(identities)
    identities.map { identity_name(it) }.join(", ")
  end

  def identity_name(identity)
    name, version, platform = identity
    (platform == "ruby") ? "#{name}-#{version}" : "#{name}-#{version}-#{platform}"
  end

  class RubyGemsClient
    API_ROOT = "https://rubygems.org/api/v1/versions"
    WAIT_ATTEMPTS = 20
    WAIT_INTERVAL = 3

    def sha_for(name, version, platform)
      versions(name).find do |candidate|
        candidate.fetch("number") == version && candidate.fetch("platform") == platform
      end&.fetch("sha")
    end

    def wait_for(identity, expected_sha)
      WAIT_ATTEMPTS.times do
        @versions = {}
        sha = sha_for(*identity)
        return if sha == expected_sha
        raise "#{ReleaseArtifacts.identity_name(identity)} appeared with a different SHA-256" if sha

        sleep WAIT_INTERVAL
      end

      raise "timed out waiting for #{ReleaseArtifacts.identity_name(identity)} to appear on RubyGems.org"
    end

    private

    def versions(name)
      @versions ||= {}
      @versions[name] ||= begin
        uri = URI("#{API_ROOT}/#{URI.encode_www_form_component(name)}.json")
        response = Net::HTTP.get_response(uri)

        case response
        when Net::HTTPSuccess then JSON.parse(response.body)
        when Net::HTTPNotFound then []
        else raise "RubyGems.org returned HTTP #{response.code} for #{uri}"
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift

  case command
  when "source-matrix"
    puts JSON.generate(ReleaseArtifacts.source_matrix)
  when "native-matrix"
    puts JSON.generate(ReleaseArtifacts.native_matrix)
  when "verify"
    directory = ARGV.fetch(0)
    version = ARGV.fetch(1)
    manifest = ARGV[2]
    artifacts = ReleaseArtifacts.verify(directory, version:, manifest:)
    puts "Verified #{artifacts.length} release artifacts for #{version}"
  when "publish"
    directory = ARGV.fetch(0)
    version = ARGV.fetch(1)
    ReleaseArtifacts.publish(directory, version:)
  else
    abort "Usage: #{$PROGRAM_NAME} source-matrix|native-matrix|verify DIRECTORY VERSION [MANIFEST]|publish DIRECTORY VERSION"
  end
end
