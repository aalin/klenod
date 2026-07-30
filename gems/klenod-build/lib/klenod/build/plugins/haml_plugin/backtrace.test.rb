# frozen_string_literal: true

require_relative "test_support"

class Klenod::Build::Plugins::HamlPlugin::BacktraceTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_transformer_rewrites_error_backtraces_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          %main
            %h1 Hello
            = raise "boom"
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin::Plugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::Runtime::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:3:in /, error.backtrace.fetch(0))
    end
  end

  def test_haml_transformer_rewrites_ruby_filter_errors_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def explode
              raise "filter boom"
            end

          %main
            = explode
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin::Plugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::Runtime::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:3:in /, error.backtrace.fetch(0))
    end
  end

  def test_haml_transformer_rewrites_nested_script_errors_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def initialize
              @items = [1, 2]
            end

          %ul
            = @items.map do |item|
              %li= raise "nested boom" if item == 2
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin::Plugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::Runtime::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:8:in /, error.backtrace.fetch(0))
    end
  end

  def test_haml_transformer_rewrites_dynamic_attribute_errors_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          %main{ class: (raise "class boom") }
            %h1 Hello
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin::Plugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::Runtime::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:1:in /, error.backtrace.fetch(0))
    end
  end

  def test_haml_transformer_rewrites_ruby_filter_method_called_from_markup
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def title
              raise "title boom"
            end

          %main
            %h1= title
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin::Plugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      mod = context.graph.mods.fetch(record.id)
      exports = mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::Runtime::BacktraceRewriter.new({"pages/page.haml" => mod}).rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/pages/page.haml")}:3:in /, error.backtrace.fetch(0))
    end
  end

  def test_haml_transformer_rewrites_imported_component_render_errors_to_component_haml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/components")
      File.write(
        "#{dir}/components/details.haml",
        <<~HAML
          :ruby
            def initialize(children: nil)
            end

          %section
            %h2 Details
            = raise "details boom"
        HAML
      )
      File.write(
        "#{dir}/page.haml",
        <<~HAML
          :ruby
            Details = import("components/details.haml")

          %main
            %Details
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin::Plugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      page_record = context.evaluate("page.haml")
      page_mod = context.graph.mods.fetch(page_record.id)
      details_mod = context.graph.mods.fetch(ModuleId.new("components/details.haml", nil))
      exports = page_mod.const_get(:Exports)

      error = assert_raises(RuntimeError) { exports::Default.new.render }
      Klenod::Runtime::BacktraceRewriter
        .new(
          {
            "page.haml" => page_mod,
            "components/details.haml" => details_mod
          }
        )
        .rewrite_exception(error)

      assert_match(/\A#{Regexp.escape("#{dir}/components/details.haml")}:7:in /, error.backtrace.fetch(0))
    end
  end

  def test_haml_transformer_rewrites_line_constants_to_haml_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write(
        "#{dir}/pages/page.haml",
        <<~HAML
          :ruby
            def filter_line
              __LINE__
            end

          %main{ data_line: __LINE__ }
            = __LINE__
            = filter_line
            = "__LINE__"
            %span= __LINE__
            %section[__LINE__]
        HAML
      )

      plugin =
        Klenod::Build::Plugins::HamlPlugin::Plugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: default_plugins_with(plugin))
      record = context.evaluate("pages/page.haml")
      exports = context.exports(record)

      assert_equal([:main, 7, 3, "__LINE__", [:span, 10], [:section, {key: 11}], {data_line: 6}], exports::Default.new.render)
    end
  end
end
