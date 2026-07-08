# frozen_string_literal: true

Shared = import("../shared")
Page = import("./page.haml")
SmokedFish = import("./smoked-fish.png?width=320,640&format=png")

def self.call(_request, context)
  css_asset = context.assets_for("pages/page.css").first
  srcset =
    SmokedFish
      .variants
      .map { |variant| "#{variant.src} #{variant.descriptor}" }
      .join(", ")
  body =
    Page::Default
      .new(
        name: Shared::NAME,
        tagline: Shared::TAGLINE,
        image: SmokedFish,
        srcset: srcset
      )
      .render

  [
    200,
    {"content-type" => "text/html; charset=utf-8"},
    [
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <title>Klenod example</title>
            #{%(<link rel="stylesheet" href="#{css_asset.output_path}">) if css_asset}
          </head>
          <body>
            #{body}
          </body>
        </html>
      HTML
    ]
  ]
end
