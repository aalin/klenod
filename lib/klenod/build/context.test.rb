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

  def test_invalidate_paths_reloads_changed_module_and_reevaluates_dependents
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      dep_path = "#{dir}/dep.rb"
      File.write(dep_path, "VALUE = 41\n")
      File.write("#{dir}/pages/page.rb", "Dep = import(\"../dep\")\nVALUE = Dep::VALUE + 1\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("pages/page")

      assert_equal(42, context.graph.mods.fetch(record.id).const_get(:Exports)::VALUE)

      File.write(dep_path, "VALUE = 99\n")

      result = context.invalidate_paths([dep_path])
      updated_record = context.graph.records.fetch(record.id)
      updated_mod = context.graph.mods.fetch(record.id)

      assert_equal(["dep.rb"], result.changed_module_ids.map(&:to_s))
      assert_equal(["dep.rb"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["pages/page.rb"], result.reevaluated_module_ids.map(&:to_s))
      assert_equal(100, updated_mod.const_get(:Exports)::VALUE)
      assert_equal(1, updated_record.version)
    end
  end

  def test_invalidate_paths_removes_deleted_module_and_reports_dependent_error
    Dir.mktmpdir do |dir|
      dep_path = "#{dir}/dep.rb"
      File.write(dep_path, "VALUE = 1\n")
      File.write("#{dir}/entry.rb", "Dep = import(\"dep\")\nVALUE = Dep::VALUE\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.load("entry")

      File.delete(dep_path)

      result = context.invalidate_paths([], removed_paths: [dep_path])

      assert_equal(["dep.rb"], result.removed_module_ids.map(&:to_s))
      assert_equal(["entry.rb"], result.errors.map { |module_id, _error| module_id.to_s })
    end
  end
end
