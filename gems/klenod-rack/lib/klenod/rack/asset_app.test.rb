# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "klenod/build/asset"
require "klenod/runtime/bundle"
require_relative "../rack"
require_relative "asset_app"

class Klenod::Rack::AssetApp::Test < Minitest::Test
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
    app = Klenod::Rack::AssetApp.new(AssetSource.new(asset, "body {}"))

    response = app.response_for("/assets/home.abc123.css")

    assert_equal(200, response.status)
    assert_equal("text/css", response.headers.fetch("content-type"))
    assert_equal("7", response.headers.fetch("content-length"))
    assert_equal("public, max-age=31536000, immutable", response.headers.fetch("cache-control"))
    assert_equal("body {}", response.body)
  end

  def test_serves_asset_preload_link_headers
    asset =
      Klenod::Build::Asset.new(
        "styles/home.css",
        "abc123",
        "/assets/home.abc123.css.js",
        nil,
        "export default {};",
        "application/javascript",
        {type: :javascript, preload_assets: [{path: "/assets/home.abc123.css", as: "style"}]}
      )
    app = Klenod::Rack::AssetApp.new(AssetSource.new(asset, "export default {};"))

    response = app.response_for("/assets/home.abc123.css.js")

    assert_equal("</assets/home.abc123.css>; rel=preload; as=style", response.headers.fetch("link"))
  end

  def test_rack_gemspec_owns_rack_asset_app
    spec = Gem::Specification.load(File.expand_path("../../../klenod-rack.gemspec", __dir__))

    assert_includes(spec.files, "lib/klenod/rack.rb")
    assert_includes(spec.files, "lib/klenod/rack/asset_app.rb")
    refute(spec.files.any? { |path| path.start_with?(File.join("lib", "klenod", "http")) })
    refute(spec.files.any? { |path| path.start_with?("lib/klenod/build/") })
    refute(spec.files.any? { |path| path.end_with?(".test.rb") })
    assert(spec.dependencies.any? { |dependency| dependency.name == "klenod-runtime" })
  end

  def test_rack_call_passes_non_asset_paths_to_wrapped_app
    fallback = ->(env) { [201, {"x-path" => env.fetch("PATH_INFO")}, ["fallback"]] }
    app = Klenod::Rack::AssetApp.new(AssetSource.new(nil, nil), app: fallback)

    assert_equal(
      [201, {"x-path" => "/page"}, ["fallback"]],
      app.call({"PATH_INFO" => "/page"})
    )
  end

  def test_rack_call_returns_not_found_for_missing_assets
    app = Klenod::Rack::AssetApp.new(AssetSource.new(nil, nil))

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
      app = Klenod::Rack::AssetApp.new(bundle, assets_dir: assets_dir)

      response = app.response_for("/assets/home.abc123.css")

      assert_equal(200, response.status)
      assert_equal("public, max-age=31536000, immutable", response.headers.fetch("cache-control"))
      assert_equal("runtime bytes", response.body)
    end
  end

  def test_serves_brotli_sidecar_when_accepted
    Dir.mktmpdir do |dir|
      assets_dir = "#{dir}/public"
      FileUtils.mkdir_p("#{assets_dir}/assets")
      File.binwrite("#{assets_dir}/assets/home.abc123.css", "runtime bytes")
      File.binwrite("#{assets_dir}/assets/home.abc123.css.br", "brotli bytes")
      asset =
        Klenod::Runtime::AssetSpec.new(
          "styles/home.css",
          "abc123",
          "/assets/home.abc123.css",
          "text/css",
          {type: :css}
        )
      bundle = Klenod::Runtime::Bundle.new({}, {}, {asset.output_path => asset})
      app = Klenod::Rack::AssetApp.new(bundle, assets_dir: assets_dir)

      response = app.response_for("/assets/home.abc123.css", {"HTTP_ACCEPT_ENCODING" => "gzip, br"})

      assert_equal(200, response.status)
      assert_equal("brotli bytes", response.body)
      assert_equal("br", response.headers.fetch("content-encoding"))
      assert_equal("Accept-Encoding", response.headers.fetch("vary"))
      assert_equal("text/css", response.headers.fetch("content-type"))
      assert_equal("12", response.headers.fetch("content-length"))
    end
  end

  def test_serves_original_asset_when_brotli_is_not_accepted
    Dir.mktmpdir do |dir|
      assets_dir = "#{dir}/public"
      FileUtils.mkdir_p("#{assets_dir}/assets")
      File.binwrite("#{assets_dir}/assets/home.abc123.css", "runtime bytes")
      File.binwrite("#{assets_dir}/assets/home.abc123.css.br", "brotli bytes")
      asset =
        Klenod::Runtime::AssetSpec.new(
          "styles/home.css",
          "abc123",
          "/assets/home.abc123.css",
          "text/css",
          {type: :css}
        )
      bundle = Klenod::Runtime::Bundle.new({}, {}, {asset.output_path => asset})
      app = Klenod::Rack::AssetApp.new(bundle, assets_dir: assets_dir)

      response = app.response_for("/assets/home.abc123.css", {"HTTP_ACCEPT_ENCODING" => "gzip, br;q=0"})

      assert_equal(200, response.status)
      assert_equal("runtime bytes", response.body)
      refute_includes(response.headers, "content-encoding")
      assert_equal("Accept-Encoding", response.headers.fetch("vary"))
    end
  end

  def test_serves_brotli_sidecar_when_wildcard_encoding_is_accepted
    Dir.mktmpdir do |dir|
      assets_dir = "#{dir}/public"
      FileUtils.mkdir_p("#{assets_dir}/assets")
      File.binwrite("#{assets_dir}/assets/home.abc123.css", "runtime bytes")
      File.binwrite("#{assets_dir}/assets/home.abc123.css.br", "brotli bytes")
      asset =
        Klenod::Runtime::AssetSpec.new(
          "styles/home.css",
          "abc123",
          "/assets/home.abc123.css",
          "text/css",
          {type: :css}
        )
      bundle = Klenod::Runtime::Bundle.new({}, {}, {asset.output_path => asset})
      app = Klenod::Rack::AssetApp.new(bundle, assets_dir: assets_dir)

      response = app.response_for("/assets/home.abc123.css", {"HTTP_ACCEPT_ENCODING" => "gzip, *;q=0.5"})

      assert_equal(200, response.status)
      assert_equal("brotli bytes", response.body)
      assert_equal("br", response.headers.fetch("content-encoding"))
    end
  end

  def test_serves_original_asset_for_invalid_accept_encoding
    Dir.mktmpdir do |dir|
      assets_dir = "#{dir}/public"
      FileUtils.mkdir_p("#{assets_dir}/assets")
      File.binwrite("#{assets_dir}/assets/home.abc123.css", "runtime bytes")
      File.binwrite("#{assets_dir}/assets/home.abc123.css.br", "brotli bytes")
      asset =
        Klenod::Runtime::AssetSpec.new(
          "styles/home.css",
          "abc123",
          "/assets/home.abc123.css",
          "text/css",
          {type: :css}
        )
      bundle = Klenod::Runtime::Bundle.new({}, {}, {asset.output_path => asset})
      app = Klenod::Rack::AssetApp.new(bundle, assets_dir: assets_dir)

      response = app.response_for("/assets/home.abc123.css", {"HTTP_ACCEPT_ENCODING" => "br;q=abc"})

      assert_equal(200, response.status)
      assert_equal("runtime bytes", response.body)
      refute_includes(response.headers, "content-encoding")
    end
  end
end
