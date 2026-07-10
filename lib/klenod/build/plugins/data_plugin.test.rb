# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require_relative "../../runtime"

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
      record = context.load("entry")
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
      record = context.load("config")
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

  def test_invalid_json_raises_parse_error
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.json", "{")

      context = Klenod::Build::Context.new(source_dir: dir)

      assert_raises(JSON::ParserError) { context.load("config.json") }
    end
  end
end
