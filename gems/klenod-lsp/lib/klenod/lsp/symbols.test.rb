# frozen_string_literal: true

require_relative "__test__/support"

class Klenod::LSP::Symbols::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def test_haml_outline_lists_bindings_methods_and_the_tag_tree
    source = <<~HAML
      :ruby
        Details = import("/components/Details")
        def greeting(name)
          "Hi \#{name}"
        end

      %section.hero
        - if greeting("x")
          %Details{ summary: "More" }
            %p Lorem ipsum
        %footer
    HAML

    symbols = Klenod::LSP::Symbols.haml_document_symbols(source)

    assert_equal(["Details", "greeting", "%section"], symbols.map(&:name))
    assert_equal([14, 6, 8], symbols.map(&:kind))
    assert_equal("/components/Details", symbols.fetch(0).detail)
    section = symbols.fetch(2)
    assert_equal(6, section.range.start.line)
    assert_equal(10, section.range.end.line)
    assert_equal(1, section.selection_range.start.character)
    assert_equal(8, section.selection_range.end.character)
    children = section.attributes.fetch(:children)
    assert_equal(["%Details", "%footer"], children.map(&:name), "script lines are transparent")
    assert_equal(5, children.fetch(0).kind)
    assert_equal(["%p"], children.fetch(0).attributes.fetch(:children).map(&:name))
    assert_nil(children.fetch(1).attributes[:children])
  end

  def test_haml_outline_is_empty_for_unparseable_documents
    assert_empty(Klenod::LSP::Symbols.haml_document_symbols("%section{\n  %p\n"))
  end

  def test_ruby_binding_symbols
    symbols = Klenod::LSP::Symbols.binding_symbols(fixture_source("entry.rb"))

    assert_equal(%w[Page Layout Details], symbols.map(&:name))
    assert_equal([2, 3, 4], symbols.map { |symbol| symbol.selection_range.start.line })
  end

  def test_workspace_symbols_match_names_and_paths_fuzzily
    workspace = fixture_workspace
    index = fixture_index(workspace, module_id("entry.rb"), module_id("pages/Page.haml"), module_id("pages/lazy.rb"))

    all = Klenod::LSP::Symbols.workspace_symbols("", index, workspace)
    assert_includes(all.map(&:name), "Details")
    assert_includes(all.map(&:name), "entry")

    details = Klenod::LSP::Symbols.workspace_symbols("dtl", index, workspace)
    assert_equal(["Details"], details.map(&:name))
    assert_equal(5, details.fetch(0).kind)
    assert_equal("components", details.fetch(0).container_name)
    assert_equal(fixture_uri("components/Details.haml"), details.fetch(0).location.uri)

    assert_equal(["layout", "lazy", "LazyPage", "Page"], Klenod::LSP::Symbols.workspace_symbols("pages/", index, workspace).map(&:name))
    assert_empty(Klenod::LSP::Symbols.workspace_symbols("zzz", index, workspace))
  end
end
