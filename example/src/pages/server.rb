# frozen_string_literal: true

Shared = import("../shared")
Page = import("./page.haml")
SmokedFish = import("./smoked-fish.png?width=320,640&format=png")

def self.call(_request, context)
  css_assets = context.assets_for_module(__FILE__, type: :css)
  srcset =
    SmokedFish
      .variants
      .map { |variant| "#{variant.src} #{variant.descriptor}" }
      .join(", ")
  body =
    Page
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
            #{css_assets.map { |asset| %(<link rel="stylesheet" href="#{asset.output_path}">) }.join("\n")}
          </head>
          <body>
            #{body}
          </body>
        </html>
      HTML
    ]
  ]
end
