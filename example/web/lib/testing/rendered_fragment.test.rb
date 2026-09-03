# frozen_string_literal: true

require "minitest/autorun"

require_relative "rendered_fragment"

class Example::RenderedFragment::Test < Minitest::Test
  def test_exposes_html_fragment_and_successful_queries
    screen = render_html(<<~HTML)
      <main>
        <h2>Settings</h2>
        <ul><li>English</li><li>Swedish</li></ul>
        <a href="/docs">Read the docs</a>
      </main>
    HTML

    assert_includes(screen.html, "<main>")
    assert_instance_of(Nokolexbor::DocumentFragment, screen.fragment)
    assert_equal("/docs", screen.get_by_role(:link, name: /docs/)["href"])
    assert_equal("h2", screen.get_by_role(:heading, name: "Settings").name)
    assert_equal(2, screen.get_all_by_role(:listitem).length)
    assert_equal("ul", screen.get_by_role(:list).name)
    assert_equal("main", screen.get_by_css("main").name)
    assert(screen.has_role?(:link, name: "Read the docs"))
    assert(screen.has_text?(/English/))
    assert(screen.has_css?("a[href]"))
  end

  def test_enforces_strict_query_cardinality
    screen = render_html("<button>Save</button><button>Save</button>")

    assert_nil(screen.query_by_role(:alert))
    assert_empty(screen.query_all_by_role(:alert))
    assert_equal(2, screen.get_all_by_role(:button).length)
    assert_equal(2, screen.query_all_by_role(:button).length)
    assert_raises(Example::QueryError) { screen.get_by_role(:alert) }
    assert_raises(Example::QueryError) { screen.get_all_by_role(:alert) }
    assert_raises(Example::QueryError) { screen.get_by_role(:button) }
    assert_raises(Example::QueryError) { screen.query_by_role(:button) }
  end

  def test_calculates_static_accessible_names
    screen = render_html(<<~HTML)
      <a href="/account" aria-label="Account settings">Profile</a>
      <button aria-labelledby="save-label"><span aria-hidden="true">Icon</span></button>
      <span id="save-label" hidden>Save changes</span>
      <label for="email">Email address</label><input id="email" type="email">
      <label>Search terms <input type="text"></label>
      <img src="portrait.jpg" alt="Portrait of Ada">
      <div role="alert">Something went wrong</div>
    HTML

    assert_equal("/account", screen.get_by_role(:link, name: "Account settings")["href"])
    assert_equal("button", screen.get_by_role(:button, name: "Save changes").name)
    assert_equal("email", screen.get_by_role(:textbox, name: "Email address")["type"])
    assert_equal("text", screen.get_by_role(:textbox, name: "Search terms")["type"])
    assert_equal("portrait.jpg", screen.get_by_role(:img, name: /Ada/)["src"])
    assert_equal("div", screen.get_by_role(:alert, name: "Something went wrong").name)
  end

  def test_excludes_hidden_elements_from_semantic_queries
    screen = render_html(<<~HTML)
      <button hidden>Hidden</button>
      <section aria-hidden="true"><button>Also hidden</button></section>
      <input type="hidden" value="secret">
      <button>Visible</button>
    HTML

    assert_equal("Visible", screen.get_by_role(:button).text)
    assert_nil(screen.query_by_text("Hidden"))
    assert_equal(3, screen.query_all_by_css("button").length)
  end

  def test_within_limits_queries_to_descendants
    screen = render_html(<<~HTML)
      <section id="first"><button>Close</button></section>
      <section id="second"><button>Close</button></section>
    HTML

    assert_raises(Example::QueryError) { screen.get_by_role(:button, name: "Close") }

    first = screen.within(screen.get_by_css("#first"))
    assert_equal("Close", first.get_by_role(:button, name: "Close").text)
    assert_nil(first.query_by_css("#second"))
  end

  def test_text_queries_normalize_whitespace_and_return_specific_elements
    screen = render_html(<<~HTML)
      <main>
        <section>
          <p> Saved\n <strong>successfully</strong> </p>
        </section>
      </main>
    HTML

    assert_equal("p", screen.get_by_text("Saved successfully").name)
    assert_equal("strong", screen.get_by_text(/success/).name)
    assert_equal("p", screen.get_by_text(/saved/i).name)
    assert_nil(screen.query_by_text("Missing"))
  end

  def test_css_queries_use_the_same_cardinality_rules
    screen = render_html('<dialog open><button class="close">Close</button></dialog>')

    assert_equal("dialog", screen.get_by_css("dialog[open]").name)
    assert_equal("button", screen.query_by_css(".close").name)
    assert_equal(["button"], screen.get_all_by_css("button").map(&:name))
    assert_empty(screen.query_all_by_css("aside"))
    assert_raises(Example::QueryError) { screen.get_by_css("aside") }
  end

  def test_diagnostics_include_query_candidates_and_rendered_html
    screen = render_html("<main><button>Save</button><button>Cancel</button></main>")

    missing = assert_raises(Example::QueryError) do
      screen.get_by_role(:button, name: "Delete")
    end
    ambiguous = assert_raises(Example::QueryError) do
      screen.get_by_role(:button)
    end

    assert_includes(missing.message, 'Query: get_by_role(:button, name: "Delete")')
    assert_includes(missing.message, "No matches found; expected exactly one.")
    assert_includes(missing.message, "Candidates:")
    assert_includes(missing.message, 'name="Save"')
    assert_includes(missing.message, "Rendered HTML:")
    assert_includes(missing.message, "<main>")
    assert_includes(ambiguous.message, "Found 2 matches; expected exactly one.")
    assert_includes(ambiguous.message, "<button>Cancel</button>")
  end

  private

  def render_html(html)
    Example::RenderedFragment.new(html)
  end
end
