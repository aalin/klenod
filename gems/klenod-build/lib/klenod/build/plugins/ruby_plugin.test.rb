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
  Context = Data.define(:source_dir, :profiler)
  GlobContext = Data.define(:source_dir, :profiler)

  def test_creates_dependencies_and_rewrites_literal_imports
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(\"../dep\")\n",
        transform_context
      )

    assert_equal(1, result.dependencies.length)
    assert_equal("../dep", result.dependencies.first.specifier)
    assert_equal(Klenod::Build::SourceLocation.new("app:/pages/page.rb", 1, 7), result.dependencies.first.loc)
    assert_includes(result.code, "__klenod_import__(\"app:/pages/page.rb:dependency:0\")")
  end

  def test_records_locations_for_imports_that_use_the_syntax_tree_scan
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(\n  \"../dep\"\n)\n",
        transform_context
      )

    assert_equal(Klenod::Build::SourceLocation.new("app:/pages/page.rb", 1, 7), result.dependencies.first.loc)
  end

  def test_rewrites_literal_imports_without_syntax_tree_scan
    profiler = Profiler.new(enabled: true)
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(\"../dep\")\n",
        transform_context(profiler:)
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
        transform_context
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
        transform_context
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
        transform_context
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
        transform_context
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
        transform_context
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
        transform_context
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_detects_command_style_imports
    assert_raises(Klenod::Build::DynamicImportError) do
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import \"../dep\"\n",
        transform_context
      )
    end
  end

  def test_skips_generated_runtime_import_helpers
    code = "KlenodImport = method(:__klenod_import__)\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        transform_context
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_creates_lazy_dependencies_and_rewrites_literal_lazy_imports
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = lazy_import(\"../dep\")\n",
        transform_context
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
        transform_context
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

      context = Klenod::Build::Context.new(source_dir: dir, plugins: [RubyPlugin.new, Klenod::Build::Plugins::TextPlugin.new])
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

  BROKEN_RUBY = "def greet\n  puts(\nend\n"

  def test_a_syntax_error_is_caught_while_collecting_not_at_evaluation
    # The rewriter only parses a file containing an import it cannot rewrite
    # literally, so this used to surface only when the module was evaluated --
    # which a production build never does.
    error = ruby_error("plain.rb", BROKEN_RUBY, Klenod::Build::Plugins::RubyPlugin::ParseError)

    assert_equal("Ruby parse error", error.kind)
    assert_equal(3, error.line)
    assert_equal(1, error.column)
    assert_equal("unexpected 'end'", error.detail)
    assert_equal(["Expected a `)` to close the arguments"], error.hints)
    assert_includes(error.message, "> 3 | end")
  end

  def test_a_syntax_error_fails_collection_without_evaluating_the_module
    Dir.mktmpdir do |dir|
      File.write("#{dir}/broken.rb", BROKEN_RUBY)

      context = Klenod::Build::Context.new(source_dir: dir)

      assert_raises(Klenod::Build::Plugins::RubyPlugin::ParseError) { context.collect("broken.rb") }
    end
  end

  def test_a_syntax_error_reports_every_thing_prism_found
    error = ruby_error("plain.rb", "VALUE = 1\ndef broken(\n", Klenod::Build::Plugins::RubyPlugin::ParseError)

    assert_equal(2, error.line)
    assert_operator(error.hints.length, :>, 1)
    assert_includes(error.hints, "Expected a `)` to close the parameters")
  end

  def test_a_syntax_error_excerpt_shows_the_original_source_not_the_rewritten_one
    Dir.mktmpdir do |dir|
      File.write("#{dir}/other.rb", "X = 1\n")
      File.write("#{dir}/entry.rb", "Other = import(\"./other.rb\")\ndef a(\nend\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      error = assert_raises(Klenod::Build::Plugins::RubyPlugin::ParseError) { context.evaluate("entry.rb") }

      assert_includes(error.message, %(import("./other.rb")))
      refute_includes(error.message, "__klenod_import__")
    end
  end

  def test_evaluation_syntax_errors_remain_the_backstop_for_generated_ruby
    # Ruby files are validated while collecting, but Ruby generated from another
    # format is not, so a codegen bug still has to be reportable.
    assert_operator(Klenod::Build::GeneratedRubyError, :<, StandardError)

    error =
      Klenod::Build::GeneratedRubyError.new(
        begin
          RubyVM::InstructionSequence.compile("def a(\nend\n", "app:/page.haml")
        rescue ScriptError => e
          e
        end,
        source: "def a(\nend\n",
        module_id: "app:/page.haml"
      )

    assert_equal("Generated Ruby syntax error", error.kind)
    assert_equal(2, error.line)
  end

  def test_a_load_error_from_the_module_is_not_reported_as_a_syntax_error
    # LoadError is a ScriptError too, but it is not a syntax error.
    Dir.mktmpdir do |dir|
      File.write("#{dir}/entry.rb", "require \"no_such_library_anywhere\"\n")

      context = Klenod::Build::Context.new(source_dir: dir)

      assert_raises(LoadError) { context.evaluate("entry.rb") }
    end
  end

  def ruby_error(name, source, expected_class)
    Dir.mktmpdir do |dir|
      File.write("#{dir}/#{name}", source)
      context = Klenod::Build::Context.new(source_dir: dir)

      assert_raises(expected_class) { context.evaluate(name) }
    end
  end

  def transform_context(source_dir: nil, profiler: nil)
    Context.new(source_dir, profiler)
  end
end
