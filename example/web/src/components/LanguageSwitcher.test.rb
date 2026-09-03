# frozen_string_literal: true

LanguageSwitcher = import("./LanguageSwitcher.haml")

RawRequest = Data.define(:method, :path)

def test_renders_english_as_the_current_language
  html = render_language_switcher("/docs/assets")
  english = language_link(html, "en")
  swedish = language_link(html, "sv")

  assert_includes(html, %(<span class="code">EN</span>))
  refute_includes(html, "components/")
  assert_includes(english, %(href="/docs/assets"))
  assert_includes(english, %(aria-current="true"))
  assert_includes(swedish, %(href="/sv/dokumentation/tillgangar"))
  refute_includes(swedish, "aria-current")
end

def test_renders_swedish_as_the_current_language
  html = render_language_switcher("/sv/dokumentation/tillgangar")
  english = language_link(html, "en")
  swedish = language_link(html, "sv")

  assert_includes(html, %(<span class="code">SV</span>))
  assert_includes(english, %(href="/docs/assets"))
  refute_includes(english, "aria-current")
  assert_includes(swedish, %(href="/sv/dokumentation/tillgangar"))
  assert_includes(swedish, %(aria-current="true"))
end

private

def render_language_switcher(path)
  localized = localized_routes.canonicalize_path(path)
  request = Example::Request.from(RawRequest.new("GET", path), localized: localized)

  with_context(request: request, routes: localized_routes) do
    render(LanguageSwitcher)
  end
end

def language_link(html, locale)
  html.scan(/<a\b[^>]*>/).find { it.include?(%(hreflang="#{locale}")) }
end

def localized_routes
  @localized_routes ||= Example::LocalizedRoutes.new(
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
