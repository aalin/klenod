# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"

module GoogleFontMetricsUpdater
  REPOSITORY = "https://github.com/seek-oss/capsize"
  LATEST_COMMIT_URL = "https://api.github.com/repos/seek-oss/capsize/commits/master"
  METRICS_PATH = "packages/metrics/src/entireMetricsCollection.json"
  LICENSE_PATH = "LICENSE"
  REQUIRED_FIELDS = %w[familyName category ascent descent lineGap unitsPerEm xWidthAvg].freeze
  REQUIRED_FAMILIES = ["Arial", "Courier New", "Times New Roman"].freeze
  HTTP_HEADERS = {
    "Accept" => "application/vnd.github+json",
    "User-Agent" => "Klenod font metrics updater"
  }.freeze
  OUTPUT_DIR = File.expand_path("../gems/klenod-build/lib/klenod/build/plugins/google_fonts_plugin", __dir__)

  module_function

  def update
    ref = latest_ref
    metrics_json = download(ref, METRICS_PATH)
    license_text = download(ref, LICENSE_PATH)
    metrics = compact_metrics(JSON.parse(metrics_json))
    missing_families = REQUIRED_FAMILIES - metrics.keys
    raise "Capsize metrics are missing #{missing_families.join(", ")}" unless missing_families.empty?

    FileUtils.mkdir_p(OUTPUT_DIR)
    write(File.join(OUTPUT_DIR, "font_metrics.json"), "#{JSON.pretty_generate(metrics)}\n")
    write(File.join(OUTPUT_DIR, "font_metrics.txt"), notice(ref, license_text))
  end

  def latest_ref
    ref = JSON.parse(read(LATEST_COMMIT_URL)).fetch("sha")
    raise "GitHub returned an invalid Capsize commit SHA" unless ref.match?(/\A[0-9a-f]{40}\z/)

    ref
  end

  def compact_metrics(collection)
    collection.values.to_h do |values|
      missing_fields = REQUIRED_FIELDS.reject { |field| values.key?(field) }
      unless missing_fields.empty?
        raise "Capsize metrics for #{values["familyName"] || "an unknown family"} are missing #{missing_fields.join(", ")}"
      end

      [values.fetch("familyName"), REQUIRED_FIELDS.to_h { |field| [field, values.fetch(field)] }]
    end.sort.to_h
  end

  def download(ref, path)
    read("https://raw.githubusercontent.com/seek-oss/capsize/#{ref}/#{path}")
  end

  def read(url, redirects: 5)
    response = Net::HTTP.get_response(URI(url), HTTP_HEADERS)

    case response
    when Net::HTTPSuccess
      response.body
    when Net::HTTPRedirection
      raise "Too many redirects while downloading #{url}" if redirects.zero?

      location = response["location"] || raise("Redirect from #{url} did not include a location")
      read(URI.join(url, location).to_s, redirects: redirects - 1)
    else
      raise "Could not download #{url}: HTTP #{response.code}"
    end
  end

  def notice(ref, license_text)
    <<~NOTICE
      Font metrics in font_metrics.json are taken from the Capsize metrics collection.

      Update them to the latest Capsize revision from the Klenod repository root:

          bundle exec rake google_fonts:metrics:update

      Project: #{REPOSITORY}
      Commit: #{ref}
      Source: #{METRICS_PATH}

      #{license_text.rstrip}
    NOTICE
  end

  def write(path, contents)
    temporary_path = "#{path}.tmp.#{$$}"
    File.binwrite(temporary_path, contents)
    File.rename(temporary_path, path)
  ensure
    FileUtils.rm_f(temporary_path) if temporary_path
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: bundle exec ruby tools/update_google_font_metrics.rb" unless ARGV.empty?

  GoogleFontMetricsUpdater.update
end
