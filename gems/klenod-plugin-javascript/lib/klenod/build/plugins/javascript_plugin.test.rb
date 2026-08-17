# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require "klenod/build/source_map"
require "klenod/plugin/css"
require "klenod/plugin/javascript"
require "klenod/runtime"

class Klenod::Build::Plugins::JavaScriptPlugin::Test < Minitest::Test
  PNG_BYTES = [
    "89504e470d0a1a0a0000000d494844520000000200000003080600000083f2be9c0000001249" \
    "44415478da63fccfc00044b26060606000000d010101d750b30a0000000049454e44ae426082"
  ].pack("H*")

  def test_ruby_import_of_javascript_returns_asset_path_and_emits_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('hello')\n")
      File.write("#{dir}/entry.rb", "Script = import(\"scripts/app.js\")\nDefault = Script\n")

      context = context_for(dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      asset = context.assets_for_module(record, type: :javascript).fetch(0)

      assert_match(%r{\A/assets/scripts_app_js\.[a-f0-9]{16}\.js\z}, exports::Default)
      assert_equal(exports::Default, asset.output_path)
      assert_equal("scripts/app.js", asset.logical_name)
      assert_equal("application/javascript", asset.content_type)
      assert_equal(:javascript, asset.metadata.fetch(:type))
      assert_includes(asset.bytes, "console.log('hello')")
    end
  end

  def test_javascript_can_be_minified_in_development
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('hello');\n")

      context = context_for(dir, javascript_plugin: Klenod::Build::Plugins::JavaScriptPlugin::Plugin.new(minify: true))
      record = context.evaluate("scripts/app.js")
      asset = record.assets.find { it.metadata.fetch(:type) == :javascript }

      assert_includes(asset.bytes, "console.log(\"hello\");")
    end
  end

  def test_static_relative_imports_are_rewritten_to_hashed_asset_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import message from './message.js';\nconsole.log(message);\n")
      File.write("#{dir}/scripts/message.js", "export default 'hello';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")
      message_asset = javascript_asset(context, "scripts/message.js")

      assert_import_from(app_asset.bytes, message_asset.output_path)
    end
  end

  def test_default_image_import_is_rewritten_to_javascript_metadata_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/images"])
      File.binwrite("#{dir}/images/logo.png", PNG_BYTES)
      File.write("#{dir}/scripts/app.js", "import logo from '../images/logo.png';\nconsole.log(logo.src, logo.width);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")
      app_asset = javascript_asset(context, "scripts/app.js")
      image_asset = context.assets_for("images/logo.png").find { it.metadata[:type] == :image }
      image_module_asset = context.assets_for("images/logo.png").find { it.metadata[:type] == :javascript && it.metadata[:image_metadata] }

      assert_equal("#{image_asset.output_path}.js", image_module_asset.output_path)
      assert_import_from(app_asset.bytes, image_module_asset.output_path)
      assert_includes(image_module_asset.bytes, %("src":"#{image_asset.output_path}"))
      assert_includes(image_module_asset.bytes, %("width":2))
      assert_includes(image_module_asset.bytes, %("height":3))
      assert_includes(context.assets_for_module("scripts/app.js", type: :javascript, recursive: false).map(&:output_path), image_module_asset.output_path)
    end
  end

  def test_named_image_import_raises_clear_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/images"])
      File.binwrite("#{dir}/images/logo.png", PNG_BYTES)
      File.write("#{dir}/scripts/app.js", "import { src } from '../images/logo.png';\nconsole.log(src);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      error = assert_raises(Klenod::Build::DynamicImportError) do
        context_for(dir).evaluate("entry")
      end

      assert_includes(error.message, "Unsupported asset import \"../images/logo.png\"")
      assert_includes(error.message, "Use a default import")
    end
  end

  def test_default_svg_import_is_rewritten_to_javascript_metadata_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/images"])
      File.write("#{dir}/images/logo.svg", %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 32"><path d="M0 0h24v32H0z"/></svg>\n))
      File.write("#{dir}/scripts/app.js", "import logo from '../images/logo.svg';\nconsole.log(logo.src, logo.width);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")
      app_asset = javascript_asset(context, "scripts/app.js")
      svg_asset = context.assets_for("images/logo.svg").find { it.metadata[:type] == :svg }
      svg_module_asset = context.assets_for("images/logo.svg").find { it.metadata[:type] == :javascript && it.metadata[:svg_metadata] }

      assert_equal("#{svg_asset.output_path}.js", svg_module_asset.output_path)
      assert_import_from(app_asset.bytes, svg_module_asset.output_path)
      assert_includes(svg_module_asset.bytes, %("src":"#{svg_asset.output_path}"))
      assert_includes(svg_module_asset.bytes, %("width":24))
      assert_includes(svg_module_asset.bytes, %("height":32))
      assert_includes(svg_module_asset.bytes, %("contentType":"image/svg+xml"))
    end
  end

  def test_default_css_import_is_rewritten_to_native_css_module_import
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/styles"])
      File.write("#{dir}/styles/panel.css", ".panel { color: red; }\n")
      File.write("#{dir}/scripts/app.ts", "import styles from '../styles/panel.css';\nconsole.log(styles);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.ts\")\n")

      context = context_for(dir)
      context.evaluate("entry")
      app_asset = javascript_asset(context, "scripts/app.ts")
      stylesheet_asset = context.assets_for("styles/panel.css").find { it.metadata[:type] == :css_javascript_stylesheet }

      assert_import_from(app_asset.bytes, stylesheet_asset.output_path)
      assert_match(/with\s*\{\s*type\s*:\s*"css"\s*\}/, app_asset.bytes)
      assert_equal([{path: stylesheet_asset.output_path, as: "style"}], app_asset.metadata[:preload_assets])
      assert(context.graph.records.key?(Klenod::Build::ModuleId.new("styles/panel.css", "javascript")))
      refute(context.graph.records.key?(Klenod::Build::ModuleId.new("styles/panel.css", nil)))
      assert_nil(context.assets_for("styles/panel.css").find { it.metadata[:type] == :css })
      assert_nil(context.assets_for("styles/panel.css").find { it.metadata[:type] == :javascript && it.metadata[:css_metadata] })
      assert_empty(context.assets_for("virtual:klenod/css-helper.js"))
      assert_empty(context.assets_for_module("scripts/app.ts", type: :css))
      assert_equal([app_asset.output_path], context.assets_for_module("scripts/app.ts", type: :javascript, recursive: false).map(&:output_path))
    end
  end

  def test_javascript_css_import_invalidation_updates_only_javascript_stylesheet_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/styles"])
      css_path = "#{dir}/styles/panel.css"
      File.write(css_path, ".panel { color: red; }\n")
      File.write("#{dir}/scripts/app.ts", "import styles from '../styles/panel.css';\nconsole.log(styles);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.ts\")\n")

      context = context_for(dir)
      context.evaluate("entry")
      old_stylesheet_asset = context.assets_for("styles/panel.css").find { it.metadata[:type] == :css_javascript_stylesheet }

      File.write(css_path, ".panel { color: blue; }\n")
      result = context.invalidate_paths([css_path])
      new_stylesheet_asset = context.assets_for("styles/panel.css").find { it.metadata[:type] == :css_javascript_stylesheet }

      assert_equal(["app:/styles/panel.css?javascript"], result.reloaded_module_ids.map(&:to_s))
      refute_equal(old_stylesheet_asset.output_path, new_stylesheet_asset.output_path)
      assert_nil(context.assets_for("styles/panel.css").find { it.metadata[:type] == :css })
      assert_includes(result.added_assets, new_stylesheet_asset.output_path)
      assert_includes(result.removed_assets, old_stylesheet_asset.output_path)
    end
  end

  def test_css_import_with_css_type_attribute_preserves_attribute
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/styles"])
      File.write("#{dir}/styles/panel.css", ".panel { color: red; }\n")
      File.write("#{dir}/scripts/app.js", "import styles from '../styles/panel.css' with { type: \"css\" };\nconsole.log(styles);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")
      app_asset = javascript_asset(context, "scripts/app.js")
      stylesheet_asset = context.assets_for("styles/panel.css").find { it.metadata[:type] == :css_javascript_stylesheet }

      assert_import_from(app_asset.bytes, stylesheet_asset.output_path)
      assert_equal(1, app_asset.bytes.scan(/with\s*\{\s*type\s*:\s*"css"\s*\}/).length)
    end
  end

  def test_css_import_with_conflicting_type_attribute_raises_clear_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/styles"])
      File.write("#{dir}/styles/panel.css", ".panel { color: red; }\n")
      File.write("#{dir}/scripts/app.js", "import styles from '../styles/panel.css' with { type: \"text\" };\nconsole.log(styles);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      error = assert_raises(Klenod::Build::DynamicImportError) do
        context_for(dir).evaluate("entry")
      end

      assert_includes(error.message, "Unsupported CSS import attribute type \"text\"")
      assert_includes(error.message, "with { type: \"css\" }")
    end
  end

  def test_named_css_import_raises_clear_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/styles"])
      File.write("#{dir}/styles/panel.css", ".panel { color: red; }\n")
      File.write("#{dir}/scripts/app.js", "import { src } from '../styles/panel.css';\nconsole.log(src);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      error = assert_raises(Klenod::Build::DynamicImportError) do
        context_for(dir).evaluate("entry")
      end

      assert_includes(error.message, "Unsupported asset import \"../styles/panel.css\"")
      assert_includes(error.message, "Use a default import")
    end
  end

  def test_runtime_bundle_preserves_javascript_image_import_assets
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(["#{dir}/scripts", "#{dir}/images"])
      File.binwrite("#{dir}/images/logo.png", PNG_BYTES)
      File.write("#{dir}/scripts/app.js", "import logo from '../images/logo.png';\nconsole.log(logo.src);\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")
      output = "#{dir}/bundle.mpk"

      context = context_for(dir, mode: :build)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      image_asset = bundle.assets.values.find { it.metadata[:type] == :image }
      image_module_asset = bundle.assets.values.find { it.metadata[:type] == :javascript && it.metadata[:image_metadata] }

      assert_match(%r{\A/assets/logo\.[a-f0-9]{16}\.png\z}, image_asset.output_path)
      assert_equal("#{image_asset.output_path}.js", image_module_asset.output_path)
      assert(loaded.assets.key?(image_asset.output_path))
      assert(loaded.assets.key?(image_module_asset.output_path))
    end
  end

  def test_re_exports_are_rewritten_to_hashed_asset_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "export { value } from './dep.js';\n")
      File.write("#{dir}/scripts/dep.js", "export const value = 1;\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")
      dep_asset = javascript_asset(context, "scripts/dep.js")

      assert_import_from(app_asset.bytes, dep_asset.output_path)
    end
  end

  def test_literal_dynamic_imports_are_rewritten_to_hashed_asset_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "button.addEventListener('click', () => import('./panel.js'));\n")
      File.write("#{dir}/scripts/panel.js", "export default 'panel';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")
      panel_asset = javascript_asset(context, "scripts/panel.js")

      assert_dynamic_import(app_asset.bytes, panel_asset.output_path)
    end
  end

  def test_extensionless_relative_javascript_imports_resolve_to_js_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import './boot';\n")
      File.write("#{dir}/scripts/boot.js", "console.log('boot');\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")
      boot_asset = javascript_asset(context, "scripts/boot.js")

      assert_side_effect_import(app_asset.bytes, boot_asset.output_path)
    end
  end

  def test_external_url_imports_are_left_unchanged
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import 'https://cdn.example.com/app.js';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.js")

      assert_side_effect_import(app_asset.bytes, "https://cdn.example.com/app.js")
      assert_equal(1, context.assets_for("scripts/app.js").count { it.metadata.fetch(:type) == :javascript })
    end
  end

  def test_bare_specifiers_raise_clear_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import React from 'react';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.js\")\n")

      error = assert_raises(Klenod::Build::DynamicImportError) do
        context_for(dir).evaluate("entry")
      end

      assert_includes(error.message, "Unsupported JavaScript import \"react\"")
      assert_includes(error.message, "Only relative, app-root, and external URL imports are supported")
    end
  end

  def test_runtime_bundle_preserves_javascript_import_value_and_asset_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "import './dep.js';\nconsole.log('bundle')\n")
      File.write("#{dir}/scripts/dep.js", "console.log('dep')\n")
      File.write("#{dir}/entry.rb", "Script = import(\"scripts/app.js\")\nDefault = Script\n")
      output = "#{dir}/bundle.mpk"

      context = context_for(dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)

      assert_match(%r{\A/assets/scripts_app_js\.[a-f0-9]{16}\.js\z}, loaded.exports("entry")::Default)
      assert_equal(2, bundle.assets.count { |_path, asset| asset.metadata.fetch(:type) == :javascript })
      assert_equal(bundle.assets.keys, loaded.assets.keys)
    end
  end

  def test_ruby_import_of_jsx_returns_custom_element_descriptor
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write(
        "#{dir}/scripts/clock.jsx",
        <<~JS
          export default class ClockElement extends HTMLElement {
            connectedCallback() {
              this.append(<span hidden>Clock</span>);
            }
          }
        JS
      )
      File.write("#{dir}/entry.rb", "Clock = import(\"scripts/clock.jsx\")\nDefault = Clock\n")

      context = context_for(dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      asset = javascript_asset(context, "scripts/clock.jsx")
      runtime_asset = javascript_asset(context, "virtual:klenod/jsx-runtime.js")

      assert_equal(true, exports::Default.fetch(:__klenod_custom_element))
      assert_match(/\Aklenod-scripts-clock-jsx-[a-f0-9]{8}\z/, exports::Default.fetch(:tag))
      assert_equal(asset.output_path, exports::Default.fetch(:asset_path))
      assert_includes(asset.bytes, %(from "#{runtime_asset.output_path}"))
      assert_match(/h\("span",\s*\{/, asset.bytes)
      assert_match(/hidden:\s*true/, asset.bytes)
      assert_includes(asset.bytes, "Object.defineProperty(ClockElement, \"__klenodCustomElementTag\"")
      assert_includes(asset.bytes, "customElements.define(#{exports::Default.fetch(:tag).inspect}, ClockElement);")
      assert_includes(runtime_asset.bytes, "type.__klenodCustomElementTag")
    end
  end

  def test_runtime_bundle_preserves_custom_element_descriptor
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write(
        "#{dir}/scripts/clock.jsx",
        <<~JS
          export default class ClockElement extends HTMLElement {}
        JS
      )
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/clock.jsx\")\n")
      output = "#{dir}/bundle.mpk"

      context = context_for(dir, mode: :build)
      context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      descriptor = loaded.exports("entry")::Default

      assert_equal(true, descriptor.fetch(:__klenod_custom_element))
      assert_match(/\Aklenod-scripts-clock-jsx-[a-f0-9]{8}\z/, descriptor.fetch(:tag))
      assert_match(%r{\A/assets/scripts_clock_jsx\.[a-f0-9]{16}\.js\z}, descriptor.fetch(:asset_path))
    end
  end

  def test_jsx_custom_element_can_default_export_identifier
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write(
        "#{dir}/scripts/clock.jsx",
        <<~JS
          class ClockElement extends HTMLElement {}
          export default ClockElement;
        JS
      )

      context = context_for(dir)
      context.evaluate("scripts/clock.jsx")
      asset = javascript_asset(context, "scripts/clock.jsx")

      assert_includes(asset.bytes, "customElements.define(\"klenod-scripts-clock-jsx-")
      assert_includes(asset.bytes, ", ClockElement);")
    end
  end

  def test_jsx_custom_element_requires_supported_default_export
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write(
        "#{dir}/scripts/clock.jsx",
        <<~JS
          export const ClockElement = class extends HTMLElement {};
        JS
      )

      error = assert_raises(Klenod::Build::Error) do
        context_for(dir).evaluate("scripts/clock.jsx")
      end

      assert_includes(error.message, "\"custom element\" modules must default-export")
    end
  end

  def test_javascript_source_maps_can_be_disabled
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('hello');\n")

      context = context_for(dir, javascript_plugin: Klenod::Build::Plugins::JavaScriptPlugin::Plugin.new(source_maps: false))
      record = context.evaluate("scripts/app.js")

      assert_equal([:javascript], record.assets.map { it.metadata.fetch(:type) })
      refute_includes(record.assets.fetch(0).bytes, "sourceMappingURL")
    end
  end

  def test_javascript_source_maps_are_emitted_in_development
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      source = "console.log('hello');\n"
      File.write("#{dir}/scripts/app.js", source)

      context = context_for(dir)
      record = context.evaluate("scripts/app.js")
      js_asset = record.assets.find { it.metadata.fetch(:type) == :javascript }
      map_asset = record.assets.find { it.metadata.fetch(:type) == :javascript_source_map }
      source_map = JSON.parse(map_asset.bytes)

      assert_match(%r{\A/assets/scripts_app_js\.[a-f0-9]{16}\.js\.map\z}, map_asset.output_path)
      assert_includes(js_asset.bytes, "sourceMappingURL=#{File.basename(map_asset.output_path)}")
      assert_equal(3, source_map.fetch("version"))
      assert_equal(["scripts/app.js"], source_map.fetch("sources"))
      assert_equal([source], source_map.fetch("sourcesContent"))
    end
  end

  def test_javascript_source_maps_are_not_emitted_in_build_mode_by_default
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.js", "console.log('hello');\n")

      context = context_for(dir, mode: :build)
      record = context.collect("scripts/app.js").record

      assert_equal([:javascript], record.assets.map { it.metadata.fetch(:type) })
      assert_includes(record.assets.fetch(0).bytes, "console.log(\"hello\");")
    end
  end

  def test_javascript_source_maps_preserve_mappings_after_dependency_rewrites
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/dep.js", "export const dep = 1;\n")
      File.write(
        "#{dir}/scripts/app.js",
        <<~JS
          import { dep } from "./dep.js";
          console.log(dep);
          console.log("done");
        JS
      )

      context = context_for(dir)
      record = context.evaluate("scripts/app.js")
      map_asset = record.assets.find { it.metadata.fetch(:type) == :javascript_source_map }
      source_map = Klenod::Build::SourceMap::Map.parse(map_asset.bytes)

      assert_equal(["scripts/app.js"], source_map.sources)
      assert_equal([0, 1, 2, 3], source_map.segments.map(&:original_line))
      assert_equal([0, 1, 2, 3], source_map.segments.map(&:generated_line))
    end
  end

  def test_typescript_import_emits_javascript_asset
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.ts", "const message: string = 'hello';\nexport default message;\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.ts\")\n")

      context = context_for(dir)
      record = context.evaluate("entry")
      asset = javascript_asset(context, "scripts/app.ts")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_match(%r{\A/assets/scripts_app_ts\.[a-f0-9]{16}\.js\z}, exports::Default)
      assert_equal("scripts/app.ts", asset.logical_name)
      assert_includes(asset.bytes, "const message = 'hello'")
      refute_includes(asset.bytes, ": string")
    end
  end

  def test_tsx_custom_element_import_returns_descriptor
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write(
        "#{dir}/scripts/clock.tsx",
        <<~TS
          export default class ClockElement extends HTMLElement {
            connectedCallback(): void {
              this.append(<><span>Clock</span></>);
            }
          }
        TS
      )
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/clock.tsx\")\n")

      context = context_for(dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      asset = javascript_asset(context, "scripts/clock.tsx")

      assert_equal(true, exports::Default.fetch(:__klenod_custom_element))
      assert_match(/\Aklenod-scripts-clock-tsx-[a-f0-9]{8}\z/, exports::Default.fetch(:tag))
      assert_equal(asset.output_path, exports::Default.fetch(:asset_path))
      assert_includes(asset.bytes, "customElements.define(#{exports::Default.fetch(:tag).inspect}, ClockElement);")
      assert_match(/h\(Fragment,\s*null/, asset.bytes)
      refute_includes(asset.bytes, ": void")
    end
  end

  def test_typescript_static_imports_are_rewritten_to_hashed_asset_paths
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.ts", "import { message } from './message';\nconsole.log(message);\n")
      File.write("#{dir}/scripts/message.ts", "export const message: string = 'hello';\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.ts\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.ts")
      message_asset = javascript_asset(context, "scripts/message.ts")

      assert_import_from(app_asset.bytes, message_asset.output_path)
    end
  end

  def test_typescript_can_import_javascript_with_explicit_extension
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      File.write("#{dir}/scripts/app.ts", "import './boot.js';\n")
      File.write("#{dir}/scripts/boot.js", "console.log('boot');\n")
      File.write("#{dir}/entry.rb", "Default = import(\"scripts/app.ts\")\n")

      context = context_for(dir)
      context.evaluate("entry")

      app_asset = javascript_asset(context, "scripts/app.ts")
      boot_asset = javascript_asset(context, "scripts/boot.js")

      assert_side_effect_import(app_asset.bytes, boot_asset.output_path)
    end
  end

  def test_typescript_source_maps_reference_original_typescript
    skip "native parser is not compiled" unless Klenod::Plugin::JavaScript::Parser.native?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/scripts")
      source = "const message: string = 'hello';\n"
      File.write("#{dir}/scripts/app.ts", source)

      context = context_for(dir)
      record = context.evaluate("scripts/app.ts")
      map_asset = record.assets.find { it.metadata.fetch(:type) == :javascript_source_map }
      source_map = JSON.parse(map_asset.bytes)

      assert_equal(["scripts/app.ts"], source_map.fetch("sources"))
      assert_equal([source], source_map.fetch("sourcesContent"))
    end
  end

  private

  def context_for(dir, mode: :development, javascript_plugin: Klenod::Build::Plugins::JavaScriptPlugin::Plugin.new)
    Klenod::Build::Context.new(
      source_dir: dir,
      mode: mode,
      plugins: [
        *Klenod::Build::Context.default_plugins,
        Klenod::Build::Plugins::CssPlugin::Plugin.new,
        javascript_plugin
      ]
    )
  end

  def javascript_asset(context, logical_name)
    context.assets_for(logical_name).find { it.metadata.fetch(:type) == :javascript } || flunk("Missing asset for #{logical_name}")
  end

  def assert_import_from(source, output_path)
    assert_match(/from\s*["']#{Regexp.escape(output_path)}["']/, source)
  end

  def assert_side_effect_import(source, output_path)
    assert_match(/import\s*["']#{Regexp.escape(output_path)}["']/, source)
  end

  def assert_dynamic_import(source, output_path)
    assert_match(/import\(\s*["']#{Regexp.escape(output_path)}["']\s*\)/, source)
  end
end
