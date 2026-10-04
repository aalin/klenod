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

  DATED_TOML = <<~TOML
    released = 1979-05-27
    local = 1979-05-27T07:32:00.5
    clock = 07:32:00
    offset = 1979-05-27T07:32:00-05:00
    huge = inf
    tiny = -inf
    unknown = nan
  TOML
  DATED_YAML = "released: 2024-05-27\nat: 2001-12-14t21:59:43.10-05:00\n"

  def test_toml_local_values_import_as_plain_dates_and_utc_times
    values = evaluate_data("site.toml", DATED_TOML)

    assert_dated_toml(values)
  end

  def test_yaml_dates_and_times_import_as_ruby_values
    values = evaluate_data("site.yaml", DATED_YAML)

    assert_equal(Date.new(2024, 5, 27), values.fetch("released"))
    assert_equal(Time.new(2001, 12, 14, 21, 59, 43.1r, "-05:00"), values.fetch("at"))
    assert_equal(-18_000, values.fetch("at").utc_offset)
  end

  def test_runtime_bundle_preserves_dates_times_and_non_finite_floats
    Dir.mktmpdir do |dir|
      File.write("#{dir}/site.toml", DATED_TOML)
      File.write("#{dir}/site.yaml", DATED_YAML)
      File.write("#{dir}/entry.rb", "Toml = import(\"site.toml\")\nYaml = import(\"site.yaml\")\n")
      output = "#{dir}/bundle.mpk"

      Klenod::Build::Context.new(source_dir: dir).build(entrypoints: ["entry"], output: output)
      exports = Klenod::Runtime.load_bundle(output).exports("entry")

      assert_dated_toml(exports::Toml)
      assert_equal(Date.new(2024, 5, 27), exports::Yaml.fetch("released"))
      assert_equal(-18_000, exports::Yaml.fetch("at").utc_offset)
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
    assert_includes(Klenod::Build::SourceExcerpt.strip(error.message), "╭─[app:/config.json:3:7]")
  end

  def test_a_parse_error_knows_the_file_it_came_from
    error = parse_error("config.json", BROKEN_JSON, Klenod::Build::Plugins::JsonPlugin::ParseError)

    assert_equal("config.json", File.basename(error.path))
    assert(File.absolute_path?(error.path))
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
    assert_equal(10, error.column)
    # The parser repeats the location in its message; the title and caret carry it.
    assert_equal("Unexpected \"\\n\": expected a value", error.detail)
    assert_includes(Klenod::Build::SourceExcerpt.strip(error.message), "╭─[app:/site.toml:2:10]")
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

  def evaluate_data(name, source)
    Dir.mktmpdir do |dir|
      File.write("#{dir}/#{name}", source)
      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate(name)

      context.graph.mods.fetch(record.id).const_get(:Exports)::Default
    end
  end

  def assert_dated_toml(values)
    assert_instance_of(Date, values.fetch("released"))
    assert_equal(Date.new(1979, 5, 27), values.fetch("released"))

    # Local datetimes and times keep their clock time in UTC, as plain Times.
    assert_instance_of(Time, values.fetch("local"))
    assert_equal(Time.utc(1979, 5, 27, 7, 32, 0.5r), values.fetch("local"))
    assert_predicate(values.fetch("local"), :utc?)
    assert_instance_of(Time, values.fetch("clock"))
    assert_equal(Time.utc(1970, 1, 1, 7, 32, 0), values.fetch("clock"))

    assert_equal(Time.new(1979, 5, 27, 7, 32, 0, "-05:00"), values.fetch("offset"))
    assert_equal(-18_000, values.fetch("offset").utc_offset)

    assert_equal(Float::INFINITY, values.fetch("huge"))
    assert_equal(-Float::INFINITY, values.fetch("tiny"))
    assert_predicate(values.fetch("unknown"), :nan?)
  end

  def parse_error(name, source, expected_class)
    Dir.mktmpdir do |dir|
      File.write("#{dir}/#{name}", source)
      context = Klenod::Build::Context.new(source_dir: dir)

      assert_raises(expected_class) { context.evaluate(name) }
    end
  end
end
