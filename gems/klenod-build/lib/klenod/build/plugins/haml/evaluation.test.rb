# frozen_string_literal: true

require_relative "../haml_test_support"

class Klenod::Build::Plugins::HamlPlugin::EvaluationTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_generates_configured_component_class
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/pages")
      File.write("#{dir}/pages/hello-world.haml", "%h1 Hello\n")

      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          component_base_class: "#{self.class.name}::FakeFramework::ComponentBase",
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [plugin])
      record = context.evaluate("pages/hello-world.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_operator(exports::Default, :<, FakeFramework::ComponentBase)
      assert_equal([:h1, "Hello"], exports::Default.new.render)
      assert_equal(exports::Default::ClassNames, exports::ClassNames)
      assert_equal(exports::Default::Translations, exports::Translations)
    end
  end

  def test_haml_transformer_renders_with_configured_factory
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %main{ class: "shell".upcase }
            %h1 Hello
            %p= "From Ruby"
        HAML
      }
    ) do |_dir, _context, record, exports|
      assert_equal([:main, [:h1, "Hello"], [:p, "From Ruby"], {class: "SHELL"}], exports::Default.new.render)
      assert_kind_of(Klenod::Runtime::SourceMap::SourceMap, record.source_map)
    end
  end

  def test_haml_transformer_can_cache_static_subtree_descriptors
    plugin = haml_plugin(cache_static_subtrees: true)

    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %article
            %h1 Hello
        HAML
      },
      plugin: plugin
    ) do |_dir, _context, record, exports|
      first = exports::Default.new.render
      second = exports::Default.new.render

      assert_equal([:article, [:h1, "Hello"]], first)
      assert_same(first, second)
      assert_predicate(first, :frozen?)
      assert_predicate(first.fetch(1), :frozen?)
      assert_raises(FrozenError) { first << "mutated" }
      assert_includes(record.transformed_source, "STATIC_SUBTREE_0")
      assert_includes(record.transformed_source, "HamlHelper.freeze_static")
    end
  end

  def test_haml_transformer_caches_static_children_inside_dynamic_parent
    plugin = haml_plugin(cache_static_subtrees: true)

    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %main
            %header
              %h1 Static
            %p= "Dynamic"
        HAML
      },
      plugin: plugin
    ) do |_dir, _context, record, exports|
      first = exports::Default.new.render
      second = exports::Default.new.render

      assert_equal([:main, [:header, [:h1, "Static"]], [:p, "Dynamic"]], first)
      assert_same(first.fetch(1), second.fetch(1))
      refute_same(first, second)
      assert_predicate(first.fetch(1), :frozen?)
      assert_includes(record.transformed_source, "STATIC_SUBTREE_0")
    end
  end

  def test_haml_transformer_does_not_cache_classed_or_dynamic_subtrees
    plugin = haml_plugin(cache_static_subtrees: true)

    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def title
              "Hello"
            end

          %article
            %h1.title Heading
            %p= title
        HAML
      },
      plugin: plugin
    ) do |_dir, _context, record, exports|
      first = exports::Default.new.render
      second = exports::Default.new.render

      assert_equal([:article, [:h1, "Heading"], [:p, "Hello"]], first)
      refute_same(first, second)
      refute_includes(record.transformed_source, "STATIC_SUBTREE_")
    end
  end

  def test_haml_transformer_supports_dynamic_attribute_fragments
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def title
              "hello"
            end

          %p{ title: title.upcase } Hello
        HAML
      }
    ) do |_dir, _context, record, exports|
      assert_equal([:p, "Hello", {title: "HELLO"}], exports::Default.new.render)
      assert_includes(record.transformed_source, "title:")
      assert_includes(record.transformed_source, "title.upcase")
    end
  end

  def test_haml_transformer_rewrites_configured_global_variables_to_props
    plugin = haml_plugin(component_base_class: "#{self.class.name}::FakeFramework::ComponentBase", global_variables: "@__props")

    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %h1= $title
        HAML
      },
      plugin: plugin
    ) do |_dir, _context, record, exports|
      assert_equal([:h1, "Hello"], exports::Default.new(title: "Hello").render)
      assert_includes(record.transformed_source, "@__props[:title]")
    end
  end

  def test_haml_transformer_renders_named_and_default_slots
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %nav
            %slot(name="button")
            %slot
        HAML
      }
    ) do |_dir, _context, record, exports|
      slots = {:button => ["Button"], nil => ["Default"]}
      children = FakeFramework::Children.new(slots)
      assert_equal([:nav, ["Button"], ["Default"]], exports::Default.new(children: children).render)
      assert_includes(record.transformed_source, "HamlHelper.render_slot(self, \"button\")")
      assert_includes(record.transformed_source, "HamlHelper.render_slot(self, nil)")
    end
  end

  def test_haml_transformer_rewrites_configured_global_variables_in_dynamic_attributes
    plugin = haml_plugin(component_base_class: "#{self.class.name}::FakeFramework::ComponentBase", global_variables: "@__props")

    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %p{ title: $title } Hello
        HAML
      },
      plugin: plugin
    ) do |_dir, _context, _record, exports|
      assert_equal([:p, "Hello", {title: "Greeting"}], exports::Default.new(title: "Greeting").render)
    end
  end

  def test_haml_transformer_rewrites_configured_global_variables_in_ruby_filters
    plugin = haml_plugin(component_base_class: "#{self.class.name}::FakeFramework::ComponentBase", global_variables: "@__props")

    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def title
              $title.upcase
            end

          %h1= title
        HAML
      },
      plugin: plugin
    ) do |_dir, _context, record, exports|
      assert_equal([:h1, "HELLO"], exports::Default.new(title: "hello").render)
      assert_includes(record.transformed_source, "@__props[:title].upcase")
    end
  end

  def test_haml_transformer_global_variable_props_are_available_before_custom_initialize
    plugin = haml_plugin(component_base_class: "#{self.class.name}::FakeFramework::ComponentBase", global_variables: "@__props")

    evaluate_haml(
      {
        "components/card.haml" => <<~HAML,
          :ruby
            def initialize
              @title = $title.upcase
            end

          %h2= @title
        HAML
        "pages/page.haml" => <<~HAML
          :ruby
            Card = import("/components/card.haml")

          %Card{ title: "Hello" }
        HAML
      },
      plugin: plugin,
      plugins: [Klenod::Build::Plugins::RubyPlugin.new, plugin]
    ) do |_dir, _context, _record, exports|
      assert_equal([:h2, "HELLO"], exports::Default.new.render)
    end
  end

  def test_haml_transformer_does_not_rewrite_global_variables_in_strings_or_special_globals
    plugin = haml_plugin(component_base_class: "#{self.class.name}::FakeFramework::ComponentBase", global_variables: "@__props")

    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def title
              ["$title", $LOAD_PATH.class.name, $1].compact.join(":")
            end

          %p= title
        HAML
      },
      plugin: plugin
    ) do |_dir, _context, record, exports|
      assert_equal([:p, "$title:Array"], exports::Default.new(title: "Hello").render)
      assert_includes(record.transformed_source, '"$title"')
      assert_includes(record.transformed_source, "$LOAD_PATH")
      assert_includes(record.transformed_source, "$1")
    end
  end

  def test_haml_transformer_supports_simple_dynamic_attribute_hashes
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def title
              "hello"
            end

          %p{ title: "\#{title}, friend", value: 2 } Hello
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:p, "Hello", {title: "hello, friend", value: 2}], exports::Default.new.render)
    end
  end

  def test_haml_transformer_supports_nested_dynamic_attribute_hashes
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def title
              "hello"
            end

          %p{ title: title.upcase, data: { count: 1 } } Hello
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:p, "Hello", {title: "HELLO", data: {count: 1}}], exports::Default.new.render)
    end
  end

  def test_haml_transformer_maps_object_reference_to_key_prop
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            User = ::Data.define(:id)

            def initialize
              @user = User.new(15)
            end

          %div[@user, :greeting] Hello
        HAML
      }
    ) do |_dir, _context, record, exports|
      assert_equal([:div, "Hello", {key: [exports::Default::User.new(15), :greeting]}], exports::Default.new.render)
      assert_includes(record.transformed_source, "key:")
      assert_includes(record.transformed_source, "[@user, :greeting]")
    end
  end

  def test_haml_transformer_maps_component_object_reference_to_key_prop
    plugin = haml_plugin
    evaluate_haml(
      {
        "components/card.haml" => <<~HAML,
          :ruby
            def initialize(key:, children: nil)
              @key = key
              @children = children
            end

          %article
            = @key
            = @children
        HAML
        "page.haml" => <<~HAML
          :ruby
            Card = import("components/card.haml")
            User = ::Data.define(:id)

            def initialize
              @user = User.new(15)
            end

          %Card[@user]
            Hello
        HAML
      },
      entry: "page.haml",
      plugin: plugin,
      plugins: [Klenod::Build::Plugins::RubyPlugin.new, plugin]
    ) do |_dir, _context, _record, exports|
      user = exports::Default::User.new(15)

      assert_equal([:article, user, ["Hello"]], exports::Default.new.render)
    end
  end

  def test_haml_transformer_supports_glob_imports
    with_haml_context(
      {
        "pages/icons/b.txt" => "b",
        "pages/icons/a.txt" => "a",
        "pages/page.haml" => <<~HAML
          :ruby
            Icons = import_glob("./icons/*.txt")

          %p= Icons.keys.join(",")
        HAML
      }
    ) do |_dir, context, _plugin|
      record = context.collect("pages/page.haml").record

      assert_equal(["./icons/a.txt", "./icons/b.txt"], record.dependencies.select { it.kind == :haml_import }.map(&:specifier))
      assert_equal(["pages/icons/*.txt"], record.watched_patterns.select { it.kind == :import_glob }.map(&:glob))
      assert_includes(record.transformed_source, "\"./icons/a.txt\" => __klenod_import__(\"pages/page.haml:dependency:0\")")
    end
  end

  def test_haml_transformer_supports_markdown_filters
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %article
            :markdown
              # Hello

              A [link](https://example.com).
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal(
        [
          :article,
          [
            [:h1, "Hello", {id: "hello"}],
            [:p, "A ", [:a, "link", {href: "https://example.com"}], "."]
          ]
        ],
        exports::Default.new.render
      )
    end
  end

  def test_haml_markdown_filters_use_markdown_components_file
    evaluate_haml(
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
        "pages/page.haml" => <<~HAML
          :markdown
            # Hello
        HAML
      },
      plugins: default_plugins_with(haml_plugin)
    ) do |_dir, _context, record, exports|
      assert_equal([:heading, "Hello", {id: "hello"}], exports::Default.new.render)
      assert_equal(["/markdown-components"], record.dependencies.select { it.kind == :markdown_components }.map(&:specifier))
      assert_equal(["markdown-components.rb"], record.watched_patterns.select { it.kind == :markdown_components }.map(&:glob))
    end
  end

  def test_haml_transformer_supports_parsed_inline_tag_values
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def title
              "Hello"
            end

          %p= title
        HAML
      }
    ) do |_dir, _context, record, exports|
      assert_equal([:p, "Hello"], exports::Default.new.render)
      assert_includes(record.transformed_source, "(title)")
    end
  end

  def test_haml_transformer_maps_inner_whitespace_marker_to_left_space
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %p
            before
            %a{ href: "#" }< link
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:p, "before", " ", [:a, "link", {href: "#"}]], exports::Default.new.render)
    end
  end

  def test_haml_transformer_does_not_add_space_before_nested_script_tag
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def value
              "hello"
            end

          %pre
            %code= value
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:pre, [:code, "hello"]], exports::Default.new.render)
    end
  end

  def test_haml_transformer_does_not_add_space_after_silent_setup_script
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          - value = "hello"

          %code= value
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([nil, [:code, "hello"]], exports::Default.new.render)
    end
  end

  def test_haml_transformer_keeps_inner_whitespace_marker_across_silent_setup_script
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def value
              "hello"
            end

          %pre
            before
            - class_name = "language-text"
            %code<= value
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:pre, "before", nil, " ", [:code, "hello"]], exports::Default.new.render)
    end
  end

  def test_haml_transformer_keeps_outer_whitespace_marker_across_silent_setup_script
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def value
              "hello"
            end

          %p
            %span<> before
            - class_name = "language-text"
            %code= value
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:p, [:span, "before"], nil, " ", [:code, "hello"]], exports::Default.new.render)
    end
  end

  def test_haml_transformer_adds_space_before_nested_script_tag_with_inner_whitespace_marker
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          :ruby
            def value
              "hello"
            end

          %pre
            before
            %code<= value
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:pre, "before", " ", [:code, "hello"]], exports::Default.new.render)
    end
  end

  def test_haml_transformer_does_not_add_edge_space_for_isolated_whitespace_marker
    evaluate_haml({"pages/page.haml" => "%a{ href: \"#\" }< link\n"}) do |_dir, _context, _record, exports|
      assert_equal([:a, "link", {href: "#"}], exports::Default.new.render)
    end
  end

  def test_haml_transformer_maps_outer_whitespace_marker_to_right_space
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %p
            %a{ href: "#" }> link
            after
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:p, [:a, "link", {href: "#"}], " ", "after"], exports::Default.new.render)
    end
  end

  def test_haml_transformer_maps_both_whitespace_markers
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %p
            before
            %a{ href: "#" }<> link
            after
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:p, "before", " ", [:a, "link", {href: "#"}], " ", "after"], exports::Default.new.render)
    end
  end

  def test_haml_transformer_maps_whitespace_markers_around_nested_tag
    evaluate_haml(
      {
        "pages/page.haml" => <<~HAML
          %p
            before
            %a{ href: "#" }<> link
            after
        HAML
      }
    ) do |_dir, _context, _record, exports|
      assert_equal([:p, "before", " ", [:a, "link", {href: "#"}], " ", "after"], exports::Default.new.render)
    end
  end

  def test_haml_transformer_supports_ruby_filter_and_attributes
    evaluate_haml(
      {
        "pages/handlers.haml" => <<~HAML
          :ruby
            def handle_click
              :clicked
            end

          %button{ onclick: handle_click } Click me
        HAML
      },
      entry: "pages/handlers.haml",
      plugin: haml_plugin(component_base_class: "#{self.class.name}::FakeFramework::ComponentBase")
    ) do |_dir, _context, record, exports|
      assert_operator(exports::Default, :<, FakeFramework::ComponentBase)
      assert_equal([:button, "Click me", {onclick: :clicked}], exports::Default.new.render)
      assert_match(/SourceMapMark:2/, record.transformed_source)
      assert_match(/SourceMapMark:6/, record.transformed_source)
    end
  end

  def test_haml_transformer_supports_script_blocks_with_children
    plugin = haml_plugin
    evaluate_haml(
      {
        "pages/list.haml" => <<~HAML
          :ruby
            Item = ::Data.define(:name)

            def initialize
              @items = [Item.new("A"), Item.new("B")]
            end

          %ul
            = @items.map do |item|
              %li= item.name
        HAML
      },
      entry: "pages/list.haml",
      plugin: plugin,
      plugins: [plugin]
    ) do |_dir, _context, record, exports|
      assert_equal([:ul, [[:li, "A"], [:li, "B"]]], exports::Default.new.render)
      assert_match(/SourceMapMark:8/, record.transformed_source)
      assert_match(/SourceMapMark:9/, record.transformed_source)
    end
  end

  def test_haml_transformer_supports_brace_script_blocks_with_children
    plugin = haml_plugin
    evaluate_haml(
      {
        "pages/list.haml" => <<~HAML
          :ruby
            Item = ::Data.define(:name)

            def initialize
              @items = [Item.new("A"), Item.new("B")]
            end

          %ul
            = @items.map { |item|
              %li= item.name
        HAML
      },
      entry: "pages/list.haml",
      plugin: plugin,
      plugins: [plugin]
    ) do |_dir, _context, record, exports|
      assert_equal([:ul, [[:li, "A"], [:li, "B"]]], exports::Default.new.render)
      assert_match(/SourceMapMark:8/, record.transformed_source)
      assert_match(/SourceMapMark:9/, record.transformed_source)
    end
  end

  def test_haml_transformer_supports_silent_script_blocks_with_children
    plugin = haml_plugin
    evaluate_haml(
      {
        "pages/list.haml" => <<~HAML
          :ruby
            Item = ::Data.define(:name)

            def initialize
              @items = [Item.new("A"), Item.new("B")]
              @seen = []
            end

            def seen
              @seen
            end

          %ul
            - @items.each do |item|
              - @seen << item.name
              %li= item.name
        HAML
      },
      entry: "pages/list.haml",
      plugin: plugin,
      plugins: [plugin]
    ) do |_dir, context, record, _exports|
      component = context.graph.mods.fetch(record.id).const_get(:Exports)::Default.new

      assert_equal([:ul, nil], component.render)
      assert_equal(["A", "B"], component.seen)
      assert_match(/SourceMapMark:12/, record.transformed_source)
      assert_match(/SourceMapMark:13/, record.transformed_source)
    end
  end

  def test_haml_transformer_supports_silent_brace_script_blocks_with_children
    plugin = haml_plugin
    evaluate_haml(
      {
        "pages/list.haml" => <<~HAML
          :ruby
            Item = ::Data.define(:name)

            def initialize
              @items = [Item.new("A"), Item.new("B")]
              @seen = []
            end

            def seen
              @seen
            end

          %ul
            - @items.each { |item|
              - @seen << item.name
              %li= item.name
        HAML
      },
      entry: "pages/list.haml",
      plugin: plugin,
      plugins: [plugin]
    ) do |_dir, context, record, _exports|
      component = context.graph.mods.fetch(record.id).const_get(:Exports)::Default.new

      assert_equal([:ul, nil], component.render)
      assert_equal(["A", "B"], component.seen)
      assert_match(/SourceMapMark:12/, record.transformed_source)
      assert_match(/SourceMapMark:13/, record.transformed_source)
    end
  end

  def test_haml_transformer_supports_silent_control_flow
    plugin = haml_plugin
    evaluate_haml(
      {
        "pages/conditional.haml" => <<~HAML
          :ruby
            def initialize(show:)
              @show = show
            end

          - if @show
            %p Visible
          - else
            %p Empty
        HAML
      },
      entry: "pages/conditional.haml",
      plugin: plugin,
      plugins: [plugin]
    ) do |_dir, _context, record, exports|
      assert_nil(exports::Default.new(show: true).render)
      assert_nil(exports::Default.new(show: false).render)
      assert_match(/SourceMapMark:7/, record.transformed_source)
      assert_match(/SourceMapMark:9/, record.transformed_source)
    end
  end

  def test_haml_transformer_supports_output_control_flow
    plugin = haml_plugin
    evaluate_haml(
      {
        "pages/conditional.haml" => <<~HAML
          :ruby
            def initialize(show:)
              @show = show
            end

          %section
            = if @show
              %p Visible
            = else
              %p Empty
        HAML
      },
      entry: "pages/conditional.haml",
      plugin: plugin,
      plugins: [plugin]
    ) do |_dir, _context, record, exports|
      assert_equal([:section, [:p, "Visible"]], exports::Default.new(show: true).render)
      assert_equal([:section, [:p, "Empty"]], exports::Default.new(show: false).render)
      assert_match(/SourceMapMark:8/, record.transformed_source)
      assert_match(/SourceMapMark:10/, record.transformed_source)
    end
  end

  def test_haml_transformer_supports_output_control_flow_without_else
    plugin =
      Klenod::Build::Plugins::HamlPlugin.new(
        factory: "#{self.class.name}::FakeFramework::H"
      )
    context = Klenod::Build::Context.new(source_dir: TEST_FIXTURE_DIR, plugins: [plugin])
    record = context.evaluate("haml/output_conditional_without_else.haml")
    exports = context.graph.mods.fetch(record.id).const_get(:Exports)

    assert_equal([:section, [:p, "Visible"]], exports::Default.new(show: true).render)
    assert_equal([:section, nil], exports::Default.new(show: false).render)
    assert_match(/SourceMapMark:8/, record.transformed_source)
  end

  def test_haml_imports_haml_component_classes_for_capitalized_tags
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/components")
      File.write(
        "#{dir}/components/details.haml",
        <<~HAML
          :ruby
            def initialize(summary:, children: nil)
              @summary = summary
              @children = children
            end

          %details
            %summary= @summary
            = @children
        HAML
      )
      File.write(
        "#{dir}/page.haml",
        <<~HAML
          :ruby
            Details = import("components/details.haml")

          %Details{ summary: "Mer information" }
            %p Lorem ipsum
        HAML
      )
      plugin =
        Klenod::Build::Plugins::HamlPlugin.new(
          factory: "#{self.class.name}::FakeFramework::H"
        )
      context = Klenod::Build::Context.new(source_dir: dir, plugins: [Klenod::Build::Plugins::RubyPlugin.new, plugin])
      record = context.evaluate("page.haml")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      details_class = context.graph.mods.fetch(ModuleId.new("components/details.haml", nil)).const_get(:Exports)::Default

      refute_includes(record.transformed_source, "import(\"components/details.haml\")")
      assert_includes(record.transformed_source, "__klenod_import__(\"page.haml:dependency:0\")")
      assert_equal(["page.haml:dependency:0"], record.dependencies.select { |dependency| dependency.kind == :haml_import }.map(&:id))
      assert_same(details_class, exports::Default.const_get(:Details))
      assert_equal(
        [
          :details,
          [:summary, "Mer information"],
          [[:p, "Lorem ipsum"]]
        ],
        exports::Default.new.render
      )
    end
  end
end
