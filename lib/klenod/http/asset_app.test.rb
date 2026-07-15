# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../build/asset"
require_relative "../runtime/bundle"
require_relative "../rack"
require_relative "asset_app"

class Klenod::HTTP::AssetApp::Test < Minitest::Test
  AssetSource = Data.define(:record, :bytes) do
    def asset(output_path)
      raise KeyError, output_path unless record && output_path == record.output_path

      record
    end

    def asset_bytes(output_path, assets_dir: nil)
      raise KeyError, output_path unless record && output_path == record.output_path

      if assets_dir
        File.binread(File.join(assets_dir, output_path.delete_prefix("/")))
      else
        bytes
      end
    end
  end

  def test_serves_build_context_assets
    asset =
      Klenod::Build::Asset.new(
        "styles/home.css",
        "abc123",
        "/assets/home.abc123.css",
        "styles/home.css",
        "body {}",
        "text/css",
        {type: :css}
      )
    app = Klenod::HTTP::AssetApp.new(AssetSource.new(asset, "body {}"))

    response = app.response_for("/assets/home.abc123.css")

    assert_equal(200, response.status)
    assert_equal("text/css", response.headers.fetch("content-type"))
    assert_equal("7", response.headers.fetch("content-length"))
    assert_equal("public, max-age=31536000, immutable", response.headers.fetch("cache-control"))
    assert_equal("body {}", response.body)
  end

  def test_rack_gemspec_owns_rack_asset_app
    spec = Gem::Specification.load(File.expand_path("../../../gems/klenod-rack/klenod-rack.gemspec", __dir__))

    assert_includes(spec.files, "lib/klenod/rack.rb")
    assert_includes(spec.files, "lib/klenod/rack/asset_app.rb")
    assert_includes(spec.files, "lib/klenod/http/asset_app.rb")
    refute(spec.files.any? { |path| path.start_with?("lib/klenod/build/") })
    refute(spec.files.any? { |path| path.end_with?(".test.rb") })
    assert(spec.dependencies.any? { |dependency| dependency.name == "klenod-runtime" })
  end

  def test_old_http_constant_aliases_rack_asset_app
    assert_same(Klenod::Rack::AssetApp, Klenod::HTTP::AssetApp)
    assert_same(Klenod::Rack::Response, Klenod::HTTP::Response)
  end

  def test_rack_call_passes_non_asset_paths_to_wrapped_app
    fallback = ->(env) { [201, {"x-path" => env.fetch("PATH_INFO")}, ["fallback"]] }
    app = Klenod::HTTP::AssetApp.new(AssetSource.new(nil, nil), app: fallback)

    assert_equal(
      [201, {"x-path" => "/page"}, ["fallback"]],
      app.call({"PATH_INFO" => "/page"})
    )
  end

  def test_rack_call_returns_not_found_for_missing_assets
    app = Klenod::HTTP::AssetApp.new(AssetSource.new(nil, nil))

    status, headers, body = app.call({"PATH_INFO" => "/assets/missing.css"})

    assert_equal(404, status)
    assert_equal("text/plain", headers.fetch("content-type"))
    assert_equal(["Asset not found\n"], body)
  end

  def test_serves_runtime_bundle_assets_from_assets_dir
    Dir.mktmpdir do |dir|
      assets_dir = "#{dir}/public"
      FileUtils.mkdir_p("#{assets_dir}/assets")
      File.binwrite("#{assets_dir}/assets/home.abc123.css", "runtime bytes")
      asset =
        Klenod::Runtime::AssetSpec.new(
          "styles/home.css",
          "abc123",
          "/assets/home.abc123.css",
          "text/css",
          {type: :css}
        )
      bundle = Klenod::Runtime::Bundle.new({}, {}, {asset.output_path => asset})
      app = Klenod::HTTP::AssetApp.new(bundle, assets_dir: assets_dir)

      response = app.response_for("/assets/home.abc123.css")

      assert_equal(200, response.status)
      assert_equal("public, max-age=31536000, immutable", response.headers.fetch("cache-control"))
      assert_equal("runtime bytes", response.body)
    end
  end
end
