# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require "klenod/runtime"

class Klenod::Build::Plugins::DataPlugin::Test < Minitest::Test
  def test_imports_json_yaml_toml_and_text_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/data")
      File.write("#{dir}/data/config.json", JSON.dump({"name" => "Klenod", "enabled" => true}))
      File.write("#{dir}/data/settings.yaml", "title: Hello\nitems:\n  - one\n  - two\n")
      File.write("#{dir}/data/site.toml", "title = \"Docs\"\n[meta]\ncount = 2\n")
      File.write("#{dir}/data/readme.txt", "Plain text\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Config = import("data/config.json")
          Settings = import("data/settings.yaml")
          Site = import("data/site.toml")
          Readme = import("data/readme.txt")

          VALUES = [Config, Settings, Site, Readme]
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      values = context.graph.mods.fetch(record.id).const_get(:Exports)::VALUES

      assert_equal("Klenod", values.fetch(0).fetch("name"))
      assert_equal(["one", "two"], values.fetch(1).fetch("items"))
      assert_equal(2, values.fetch(2).fetch("meta").fetch("count"))
      assert_equal("Plain text\n", values.fetch(3))
    end
  end

  def test_data_files_can_be_loaded_as_entrypoints
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.json", JSON.dump({"name" => "Klenod"}))

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("config.json")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal({"name" => "Klenod"}, exports::Default)
    end
  end

  def test_runtime_bundle_preserves_data_import_values_without_build_plugins
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.json", JSON.dump({"name" => "Klenod"}))
      File.write("#{dir}/entry.rb", "Config = import(\"config.json\")\nVALUE = Config.fetch(\"name\")\n")
      output = "#{dir}/bundle.mpk"

      Klenod::Build::Context.new(source_dir: dir).build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)

      assert_equal("Klenod", loaded.exports("entry")::VALUE)
    end
  end

  BROKEN_JSON = "{\n  \"a\": 1,\n  \"b\" 2\n}\n"
  BROKEN_YAML = "name: ok\nitems:\n  - a\nbad: [1, 2\n"
  BROKEN_TOML = "title = \"Hello\"\ninvalid =\n"

  def test_invalid_json_raises_a_located_parse_error
    error = parse_error("config.json", BROKEN_JSON, Klenod::Build::Plugins::JsonPlugin::ParseError)

    assert_equal("JSON parse error", error.kind)
    assert_equal(3, error.line)
    assert_equal(7, error.column)
    assert_equal(BROKEN_JSON, error.source)
    # The parser repeats the location in its message; the title and caret carry it.
    assert_equal("expected ':' after object key, got: '2'", error.detail)
    assert_includes(error.message, "app:/config.json:3:7: JSON parse error")
  end

  def test_invalid_yaml_raises_a_located_parse_error_with_the_parser_context_as_a_hint
    error = parse_error("settings.yaml", BROKEN_YAML, Klenod::Build::Plugins::YamlPlugin::ParseError)

    assert_equal("YAML parse error", error.kind)
    assert_equal(4, error.line)
    assert_equal(6, error.column)
    assert_equal("did not find expected ',' or ']'", error.detail)
    assert_equal(["While parsing a flow sequence"], error.hints)
  end

  def test_invalid_toml_raises_a_located_parse_error
    error = parse_error("site.toml", BROKEN_TOML, Klenod::Build::Plugins::TomlPlugin::ParseError)

    assert_equal("TOML parse error", error.kind)
    assert_equal(2, error.line)
    # citrus reports a zero-based offset into the line.
    assert_equal(10, error.column)
    # toml-rb embeds its own caret diagram, which we replace with our excerpt.
    refute_includes(error.message, "Failed to parse input on line")
  end

  def test_parse_errors_are_collected_during_invalidation_instead_of_raising
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.json", JSON.dump({"a" => 1}))
      File.write("#{dir}/entry.rb", "Config = import(\"./config.json\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("entry.rb")

      File.write("#{dir}/config.json", BROKEN_JSON)
      result = context.invalidate_paths(["#{dir}/config.json"])

      refute_empty(result.errors)
      _module_id, error = result.errors.fetch(0)
      assert_instance_of(Klenod::Build::Plugins::JsonPlugin::ParseError, error)
      assert_equal(3, error.line)
    end
  end

  def test_text_files_cannot_fail_to_parse
    Dir.mktmpdir do |dir|
      File.write("#{dir}/readme.txt", "{ not json, not yaml: [\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("readme.txt")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal("{ not json, not yaml: [\n", exports::Default)
    end
  end

  private

  def parse_error(name, source, expected_class)
    Dir.mktmpdir do |dir|
      File.write("#{dir}/#{name}", source)
      context = Klenod::Build::Context.new(source_dir: dir)

      assert_raises(expected_class) { context.evaluate(name) }
    end
  end
end
