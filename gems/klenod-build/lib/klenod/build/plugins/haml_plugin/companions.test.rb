# frozen_string_literal: true

require_relative "../haml_plugin_test_support"

class Klenod::Build::Plugins::HamlPlugin::CompanionsTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_records_companion_watched_patterns
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      plugin = haml_plugin
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")

      assert_equal(
        ["pages/page.css", "pages/page.intl.*.toml"],
        record.watched_patterns.map(&:glob)
      )
      assert_equal({}, context.graph.mods.fetch(record.id).const_get(:Exports)::Styles)
      assert_equal({}, context.graph.mods.fetch(record.id).const_get(:Exports)::Translations)
    end
  end

  def test_haml_records_plus_route_companion_watched_patterns
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/+page.haml", "%h1 Hello\n")

      plugin = haml_plugin
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))

      record = context.evaluate("pages/+page.haml")

      assert_equal(
        ["pages/+page.css", "pages/+page.intl.*.toml"],
        record.watched_patterns.map(&:glob)
      )
    end
  end

  def test_haml_loads_companion_intl_files_into_translations
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write("#{dir}/pages/page.intl.en-US.toml", "title = \"Hello\"\n[count]\nvalue = 1\n")
      File.write("#{dir}/pages/page.intl.sv-SE.toml", "title = \"Hej\"\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("pages/page.haml")
      translations = context.graph.mods.fetch(record.id).const_get(:Exports)::Translations

      assert_equal("Hello", translations.fetch("en-US").fetch("title"))
      assert_equal(1, translations.fetch("en-US").fetch("count").fetch("value"))
      assert_equal("Hej", translations.fetch("sv-SE").fetch("title"))
      assert(translations.frozen?)
      assert(translations.fetch("en-US").frozen?)
    end
  end

  def test_haml_runtime_bundle_preserves_translations
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write("#{dir}/pages/page.intl.en-US.toml", "title = \"Hello\"\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      context.build(entrypoints: ["pages/page.haml"], output: output)
      mod = Klenod::Runtime.load_bundle(output).load("pages/page.haml")
      translations = mod.const_get(:Exports)::Translations

      assert_equal("Hello", translations.fetch("en-US").fetch("title"))
    end
  end

  def test_adding_companion_css_reloads_haml_and_imports_styles
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      plugin = haml_plugin
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      haml_record = context.evaluate("pages/page.haml")

      assert_equal({}, context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles)

      File.write(css_path, ".title { color: red; }\n")
      result = context.invalidate_paths([css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_match(/title/, styles.fetch(:title))
      assert(context.graph.records.key?(ModuleId.new("pages/page.css", nil)))
    end
  end

  def test_adding_companion_css_collects_lazy_haml_owner
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Page = lazy_import("pages/page.haml")

          def self.page
            Page.call
          end
        RUBY
      )

      plugin = haml_plugin
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      context.evaluate("entry")

      refute(context.graph.records.key?(ModuleId.new("pages/page.haml", nil)))

      File.write(css_path, ".title { color: red; }\n")
      result = context.invalidate_paths([css_path])
      haml_record = context.graph.records.fetch(ModuleId.new("pages/page.haml", nil))
      css_record = context.graph.records.fetch(ModuleId.new("pages/page.css", nil))

      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      assert_equal(
        [ModuleId.new("pages/page.css", nil), ModuleId.new("virtual:klenod/haml_helper.rb", nil)],
        haml_record.resolved_dependencies.map(&:module_id)
      )
      assert_match(%r{\A/assets/pages_page_css\.[a-f0-9]{16}\.css\z}, css_record.assets.first.output_path)
    end
  end

  def test_haml_css_filter_loads_as_virtual_css_module
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :css
            .title { color: red; }

          %h1 Hello
        HAML
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")
      virtual_css_id = ModuleId.new("pages/page.haml.inline.0.css", nil)
      css_record = context.graph.records.fetch(virtual_css_id)
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(
        [virtual_css_id, ModuleId.new("virtual:klenod/haml_helper.rb", nil)],
        haml_record.resolved_dependencies.map(&:module_id)
      )
      assert_match(/title/, styles.fetch(:title))
      assert_equal(1, css_record.assets.length)
      assert_match(%r{\A/assets/pages_page_haml_inline_0_css\.[a-f0-9]{16}\.css\z}, css_record.assets.first.output_path)
      assert_includes(css_record.assets.first.bytes, "color: red")
    end
  end

  def test_haml_applies_css_tag_selector_to_matching_tag
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.css", "figure { margin: 0; }\n")
      File.write("#{dir}/pages/page.haml", "%figure Hello\n")

      plugin = haml_plugin
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      haml_record = context.evaluate("pages/page.haml")
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      rendered = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Default.new.render

      assert_match(/figure/, styles.fetch(:__figure))
      assert_equal([:figure, "Hello", {class: styles.fetch(:__figure)}], rendered)
    end
  end

  def test_haml_applies_css_class_selector_to_class_shorthand
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.css", ".image { display: block; }\nimg { width: 100%; }\n")
      File.write("#{dir}/pages/page.haml", "%img.image\n")

      plugin = haml_plugin
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      haml_record = context.evaluate("pages/page.haml")
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      rendered = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Default.new.render

      assert_equal([styles.fetch(:__img), styles.fetch(:image)].join(" "), rendered.fetch(1).fetch(:class))
    end
  end

  def test_haml_joins_static_and_dynamic_class_names_without_css
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.haml", "%h1.title{ class: [\"lead\", { active: true, hidden: false }, nil] } Hello\n")

      plugin = haml_plugin
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      haml_record = context.evaluate("pages/page.haml")
      rendered = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Default.new.render

      assert_equal(
        [ModuleId.new("virtual:klenod/haml_helper.rb", nil)],
        haml_record.resolved_dependencies.map(&:module_id)
      )
      assert_equal("title lead active", rendered.fetch(2).fetch(:class))
    end
  end

  def test_haml_joins_duplicate_class_names_from_companion_and_inline_css
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/page.css", ".title { color: red; }\n")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :css
            .title { color: blue; }

          %h1 Hello
        HAML
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      title_classes = styles.fetch(:title).split

      assert_equal(
        [ModuleId.new("pages/page.css", nil), ModuleId.new("pages/page.haml.inline.0.css", nil), ModuleId.new("virtual:klenod/haml_helper.rb", nil)],
        haml_record.resolved_dependencies.map(&:module_id)
      )
      assert_equal(2, title_classes.length)
      assert(title_classes.all? { |class_name| class_name.include?("title") })
      assert_equal(title_classes.uniq, title_classes)
    end
  end

  def test_removing_haml_css_filter_removes_virtual_css_module
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      haml_path = "#{dir}/pages/page.haml"
      File.write(
        haml_path,
        <<~HAML
          :css
            .title { color: red; }

          %h1 Hello
        HAML
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")
      virtual_css_id = ModuleId.new("pages/page.haml.inline.0.css", nil)

      assert(context.graph.records.key?(virtual_css_id))

      File.write(haml_path, "%h1 Hello\n")
      result = context.invalidate_paths([haml_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      refute(context.graph.records.key?(virtual_css_id))
      assert_equal({}, styles)
    end
  end

  def test_editing_companion_intl_reloads_haml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hello\"\n")
      result = context.invalidate_paths([intl_path])

      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(1, context.graph.records.fetch(haml_record.id).version)
    end
  end

  def test_editing_companion_css_reloads_haml_and_updates_styles
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write(css_path, ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")
      old_asset_path = context.graph.records.fetch(ModuleId.new("pages/page.css", nil)).assets.first.output_path
      old_styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      File.write(css_path, ".heading { color: blue; }\n")
      result = context.invalidate_paths([css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles
      css_record = context.graph.records.fetch(ModuleId.new("pages/page.css", nil))

      assert_equal(["pages/page.css", "pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_match(/title/, old_styles.fetch(:title))
      refute_includes(styles.keys, :title)
      assert_match(/heading/, styles.fetch(:heading))
      refute_equal(old_asset_path, css_record.assets.first.output_path)
      assert_includes(css_record.assets.first.bytes, "color: #00f")
    end
  end

  def test_adding_editing_and_removing_companion_intl_reloads_haml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hello\"\n")
      add_result = context.invalidate_paths([intl_path])
      File.write(intl_path, "title = \"Hi\"\n")
      edit_result = context.invalidate_paths([intl_path])
      File.delete(intl_path)
      remove_result = context.invalidate_paths([], removed_paths: [intl_path])

      assert_equal(["pages/page.haml"], add_result.reloaded_module_ids.map(&:to_s))
      assert_equal(["pages/page.haml"], edit_result.reloaded_module_ids.map(&:to_s))
      assert_equal(["pages/page.haml"], remove_result.reloaded_module_ids.map(&:to_s))
      assert_equal(3, context.graph.records.fetch(haml_record.id).version)
    end
  end

  def test_editing_companion_intl_updates_translations
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write(intl_path, "title = \"Hello\"\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hi\"\n")
      context.invalidate_paths([intl_path])
      translations = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Translations

      assert_equal("Hi", translations.fetch("en-US").fetch("title"))
    end
  end

  def test_malformed_companion_intl_reports_load_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      intl_path = "#{dir}/pages/page.intl.en-US.toml"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("pages/page.haml")

      File.write(intl_path, "title = \"Hello\"\ninvalid =\n")
      result = context.invalidate_paths([intl_path])

      assert_equal(["pages/page.haml"], result.errors.map { |module_id, _error| module_id.to_s })
      assert_kind_of(TomlRB::ParseError, result.errors.first.last)
    end
  end

  def test_removing_companion_css_reloads_haml_back_to_empty_styles
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      css_path = "#{dir}/pages/page.css"
      File.write("#{dir}/pages/page.haml", "%h1 Hello\n")
      File.write(css_path, ".title { color: red; }\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      haml_record = context.evaluate("pages/page.haml")

      assert_match(/title/, context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles.fetch(:title))

      File.delete(css_path)
      result = context.invalidate_paths([], removed_paths: [css_path])
      styles = context.graph.mods.fetch(haml_record.id).const_get(:Exports)::Styles

      assert_equal(["pages/page.css"], result.removed_module_ids.map(&:to_s))
      assert_equal(["pages/page.haml"], result.reloaded_module_ids.map(&:to_s))
      assert_equal({}, styles)
    end
  end
end
