# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../runtime"
require_relative "context"

class Klenod::Build::Context::Test < Minitest::Test
  def test_loads_entrypoint_and_dependencies_lazily
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write("#{dir}/pages/page.rb", "Dep = import(\"../dep\")\nVALUE = Dep::VALUE + 1\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("pages/page")
      mod = context.graph.mods.fetch(record.id)

      assert_equal(42, mod.const_get(:Exports)::VALUE)
      assert_equal(2, context.graph.records.length)
    end
  end

  def test_build_writes_marshal_bundle
    Dir.mktmpdir do |dir|
      File.write("#{dir}/dep.rb", "VALUE = 41\n")
      File.write("#{dir}/entry.rb", "Dep = import(\"dep\")\nVALUE = Dep::VALUE + 1\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      mod = loaded.load("entry")

      assert_equal(bundle.entrypoints, loaded.entrypoints)
      assert_equal(2, loaded.modules.length)
      assert_equal(42, mod.const_get(:Exports)::VALUE)
    end
  end
end
