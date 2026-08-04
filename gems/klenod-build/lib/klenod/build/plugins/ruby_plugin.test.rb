# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

require_relative "../../build/context"
require_relative "../../build/module_id"
require_relative "../../build/profiler"
require_relative "data_plugin"
require_relative "ruby_plugin"

class Klenod::Build::Plugins::RubyPlugin::Test < Minitest::Test
  RubyPlugin = Klenod::Build::Plugins::RubyPlugin::Plugin
  ModuleId = Klenod::Build::ModuleId
  Profiler = Klenod::Build::Profiler
  Context = Data.define(:profiler)
  GlobContext = Data.define(:source_dir, :profiler)

  def test_creates_dependencies_and_rewrites_literal_imports
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(\"../dep\")\n",
        nil
      )

    assert_equal(1, result.dependencies.length)
    assert_equal("../dep", result.dependencies.first.specifier)
    assert_includes(result.code, "__klenod_import__(\"app:/pages/page.rb:dependency:0\")")
  end

  def test_rewrites_literal_imports_without_syntax_tree_scan
    profiler = Profiler.new(enabled: true)
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(\"../dep\")\n",
        Context.new(profiler)
      )

    assert_equal(1, result.dependencies.length)
    assert_includes(result.code, "__klenod_import__(\"app:/pages/page.rb:dependency:0\")")
    refute_includes(profiler.totals.keys, :ruby_import_parse)
    refute_includes(profiler.totals.keys, :ruby_import_scan)
  end

  def test_rewrites_imports_with_whitespace
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import  (  \"../dep\"  )\n",
        nil
      )

    assert_equal("../dep", result.dependencies.first.specifier)
    assert_equal("Dep = __klenod_import__(\"app:/pages/page.rb:dependency:0\")\n", result.code)
  end

  def test_does_not_rewrite_import_text_inside_strings
    code = "value = \"import(\\\"../dep\\\")\"\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_does_not_rewrite_import_text_inside_comments
    code = "# import(\"../dep\")\nvalue = 1\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_does_not_fast_rewrite_receiver_import_calls
    code = "Dep = loader.import(\"../dep\")\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_does_not_fast_rewrite_namespace_import_calls
    code = "Dep = Namespace::import(\"../dep\")\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_does_not_fast_rewrite_safe_navigation_import_calls
    code = "Dep = loader&.import(\"../dep\")\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_detects_command_style_imports
    assert_raises(Klenod::Build::DynamicImportError) do
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import \"../dep\"\n",
        nil
      )
    end
  end

  def test_skips_generated_runtime_import_helpers
    code = "KlenodImport = method(:__klenod_import__)\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_creates_lazy_dependencies_and_rewrites_literal_lazy_imports
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = lazy_import(\"../dep\")\n",
        nil
      )

    assert_equal(1, result.dependencies.length)
    assert_equal("../dep", result.dependencies.first.specifier)
    refute(result.dependencies.first.eager)
    assert_includes(result.code, "__klenod_lazy_import__(\"app:/pages/page.rb:dependency:0\")")
  end

  def test_rejects_dynamic_imports
    assert_raises(Klenod::Build::DynamicImportError) do
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(name)\n",
        nil
      )
    end
  end

  def test_creates_eager_glob_dependencies_and_rewrites_to_hash
    with_files(
      "pages/gallery/b.jpg" => "b",
      "pages/gallery/a.jpg" => "a"
    ) do |dir|
      result =
        RubyPlugin.new.transform(
          ModuleId.new("pages/page.rb", nil),
          "Images = import_glob(\"./gallery/*.jpg?width=320\")\n",
          GlobContext.new(Pathname.new(dir), nil)
        )

      assert_equal(["./gallery/a.jpg?width=320", "./gallery/b.jpg?width=320"], result.dependencies.map(&:specifier))
      assert_equal(["./gallery/a.jpg", "./gallery/b.jpg"], result.dependencies.map { it.metadata.fetch(:glob_key) })
      assert(result.dependencies.all?(&:eager))
      assert_equal(["pages/gallery/*.jpg"], result.watched_patterns.map(&:glob))
      assert_includes(result.code, "\"./gallery/a.jpg\" => __klenod_import__(\"app:/pages/page.rb:dependency:0\")")
      assert_includes(result.code, "\"./gallery/b.jpg\" => __klenod_import__(\"app:/pages/page.rb:dependency:1\")")
    end
  end

  def test_creates_lazy_glob_dependencies_when_eager_is_false
    with_files("pages/icons/add.svg" => "<svg></svg>") do |dir|
      result =
        RubyPlugin.new.transform(
          ModuleId.new("pages/page.rb", nil),
          "Icons = import_glob(\"./icons/*.svg\", eager: false)\n",
          GlobContext.new(Pathname.new(dir), nil)
        )

      assert_equal(["./icons/add.svg"], result.dependencies.map(&:specifier))
      refute(result.dependencies.first.eager)
      assert_includes(result.code, "\"./icons/add.svg\" => __klenod_lazy_import__(\"app:/pages/page.rb:dependency:0\")")
    end
  end

  def test_glob_watched_pattern_matches_brace_extensions
    with_files("pages/gallery/a.jpg" => "a") do |dir|
      result =
        RubyPlugin.new.transform(
          ModuleId.new("pages/page.rb", nil),
          "Images = import_glob(\"./gallery/*.{jpg,png}\")\n",
          GlobContext.new(Pathname.new(dir), nil)
        )

      pattern = result.watched_patterns.fetch(0)
      assert(pattern.match?("pages/gallery/a.jpg"))
      assert(pattern.match?("pages/gallery/b.png"))
    end
  end

  def test_rejects_dynamic_glob_imports
    assert_raises(Klenod::Build::DynamicImportError) do
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Images = import_glob(pattern)\n",
        GlobContext.new(Pathname.new("."), nil)
      )
    end
  end

  def test_adding_glob_match_invalidates_importer
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages/gallery")
      File.write("#{dir}/pages/page.rb", "Images = import_glob(\"./gallery/*.txt\")\n")

      context = Klenod::Build::Context.new(source_dir: dir, plugins: [RubyPlugin.new, Klenod::Build::Plugins::TextPlugin::Plugin.new])
      context.collect("pages/page.rb")

      new_path = "#{dir}/pages/gallery/new.txt"
      File.write(new_path, "new")
      result = context.invalidate_paths([new_path])

      assert_equal(["app:/pages/page.rb"], result.reloaded_module_ids.map(&:to_s))
      record = context.graph.records.fetch(ModuleId.new("pages/page.rb", nil))
      assert_equal(["./gallery/new.txt"], record.dependencies.map(&:specifier))
    end
  end

  def with_files(files)
    Dir.mktmpdir do |dir|
      files.each do |path, source|
        full_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, source)
      end

      yield dir
    end
  end
end
