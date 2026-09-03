# frozen_string_literal: true

LanguageSwitcher = import("./LanguageSwitcher.haml")

RawRequest = Data.define(:method, :path)

def test_renders_english_as_the_current_language
  screen = render_language_switcher("/docs/assets")
  english = screen.get_by_role(:link, name: /English/)
  swedish = screen.get_by_role(:link, name: /Svenska/)

  assert_equal("/docs/assets", english["href"])
  assert_equal("true", english["aria-current"])
  assert_equal("/sv/dokumentation/tillgangar", swedish["href"])
  assert_nil(swedish["aria-current"])
  assert_includes(screen.html, %(<span class="code">EN</span>))
  refute_includes(screen.html, "components/")
end

def test_renders_swedish_as_the_current_language
  screen = render_language_switcher("/sv/dokumentation/tillgangar")
  english = screen.get_by_role(:link, name: /English/)
  swedish = screen.get_by_role(:link, name: /Svenska/)

  assert_equal("/docs/assets", english["href"])
  assert_nil(english["aria-current"])
  assert_equal("/sv/dokumentation/tillgangar", swedish["href"])
  assert_equal("true", swedish["aria-current"])
  assert_includes(screen.html, %(<span class="code">SV</span>))
end

private

def render_language_switcher(path)
  localized = localized_routes.canonicalize_path(path)
  request = Example::Framework::Request.from(RawRequest.new("GET", path), localized: localized)

  with_context(request: request, routes: localized_routes) do
    render(LanguageSwitcher)
  end
end

def localized_routes
  @localized_routes ||= Example::Framework::LocalizedRoutes.new(
    routes: [
      Struct.new(:match_parts).new([
        [:static, "docs", nil],
        [:static, "assets", nil]
      ])
    ],
    translations: {
      "en" => {"segments" => {"docs" => "docs", "assets" => "assets"}},
      "sv" => {"segments" => {"docs" => "dokumentation", "assets" => "tillgangar"}}
    }
  )
end
