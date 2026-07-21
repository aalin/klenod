# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "klenod/runtime"
require_relative "../context"
require_relative "markdown_plugin"

class Klenod::Build::Plugins::MarkdownPlugin::Test < Minitest::Test
  module FakeFramework
    class ComponentBase
    end

    module H
      def self.[](tag, *children, **props)
        return tag.new(**props, children: children).render if tag.is_a?(Class)

        props.empty? ? [tag, *children] : [tag, *children, props]
      end
    end
  end

  def test_markdown_import_exports_component_class
    with_context(
      {
        "page.md" => <<~MARKDOWN
          # Hello

          A [link](https://example.com).
        MARKDOWN
      }
    ) do |context|
      record = context.evaluate("page.md")
      component = context.exports(record)::Default

      assert_operator(component, :<, FakeFramework::ComponentBase)
      assert_equal(
        [
          [:h1, "Hello", {"id" => "hello"}],
          [:p, "A ", [:a, "link", {"href" => "https://example.com"}], "."]
        ],
        component.new.render
      )
    end
  end

  def test_markdown_uses_markdown_components_file_when_present
    with_context(
      {
        "markdown-components.rb" => <<~RUBY,
          class Heading
            def initialize(children: nil, **props)
              @children = children
              @props = props
            end

            def render
              [:heading, *@children, @props]
            end
          end

          Default = {h1: Heading}.freeze
        RUBY
        "page.md" => "# Hello\n"
      }
    ) do |context|
      record = context.evaluate("page.md")

      assert_equal([:heading, "Hello", {"id" => "hello"}], context.exports(record)::Default.new.render)
      assert_equal(["/markdown-components"], record.dependencies.map(&:specifier))
    end
  end

  def test_markdown_renders_raw_html_elements_as_factory_calls
    with_context(
      {
        "page.md" => <<~MARKDOWN
          <section class="intro"><p>Raw <strong>HTML</strong></p></section>
        MARKDOWN
      }
    ) do |context|
      component = context.exports(context.evaluate("page.md"))::Default

      assert_equal(
        [:section, [:p, "Raw ", [:strong, "HTML"]], {"class" => "intro"}],
        component.new.render
      )
    end
  end

  def test_markdown_renders_gfm_code_fences_and_tables
    with_context(
      {
        "page.md" => <<~MARKDOWN
          ```ruby
          puts 1
          ```

          | A | B |
          | - | - |
          | 1 | 2 |
        MARKDOWN
      }
    ) do |context|
      component = context.exports(context.evaluate("page.md"))::Default

      assert_equal(
        [
          [:pre, [:code, "puts 1\n", {"class" => "language-ruby"}]],
          [
            :table,
            [:thead, [:tr, [:th, "A"], [:th, "B"]]],
            [:tbody, [:tr, [:td, "1"], [:td, "2"]]]
          ]
        ],
        component.new.render
      )
    end
  end

  def test_runtime_bundle_preserves_markdown_imports_without_build_plugins
    Dir.mktmpdir do |dir|
      File.write("#{dir}/page.md", "# Hello\n")
      output = "#{dir}/bundle.mpk"
      context = context_for(dir)

      context.build(entrypoints: ["page.md"], output: output)
      component = Klenod::Runtime.load_bundle(output).exports("page.md")::Default

      assert_equal([:h1, "Hello", {"id" => "hello"}], component.new.render)
    end
  end

  def test_adding_markdown_components_file_invalidates_markdown_importer
    Dir.mktmpdir do |dir|
      File.write("#{dir}/page.md", "# Hello\n")
      context = context_for(dir)
      record = context.evaluate("page.md")

      assert_equal([:h1, "Hello", {"id" => "hello"}], context.exports(record)::Default.new.render)

      File.write(
        "#{dir}/markdown-components.rb",
        <<~RUBY
          class Heading
            def initialize(children: nil, **props)
              @children = children
              @props = props
            end

            def render = [:heading, *@children, @props]
          end

          Default = {h1: Heading}.freeze
        RUBY
      )
      result = context.invalidate_paths(["#{dir}/markdown-components.rb"])

      assert_equal(["page.md"], result.reloaded_module_ids.map(&:to_s))
      assert_equal([:heading, "Hello", {"id" => "hello"}], context.exports(record)::Default.new.render)
    end
  end

  def test_text_plugin_does_not_handle_markdown_files
    Dir.mktmpdir do |dir|
      File.write("#{dir}/page.md", "# Hello\n")
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [Klenod::Build::Plugins::RubyPlugin.new, Klenod::Build::Plugins::TextPlugin.new])

      assert_raises(Klenod::Build::UnsupportedFileError) { context.evaluate("page.md") }
    end
  end

  def with_context(files)
    Dir.mktmpdir do |dir|
      files.each do |path, source|
        full_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, source)
      end

      yield context_for(dir)
    end
  end

  def context_for(dir)
    Klenod::Build::Context.new(
      source_dir: dir,
      plugins: [
        Klenod::Build::Plugins::RubyPlugin.new,
        Klenod::Build::Plugins::MarkdownPlugin.new(
          component_base_class: "#{self.class.name}::FakeFramework::ComponentBase",
          factory: "#{self.class.name}::FakeFramework::H"
        ),
        Klenod::Build::Plugins::TextPlugin.new
      ]
    )
  end
end
