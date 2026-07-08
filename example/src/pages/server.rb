# frozen_string_literal: true

Shared = import("../shared")
Styles = import("../styles/home.css")
SmokedFish = import("./smoked-fish.png?width=320,640&format=png")

def self.call(_request, context)
  css_asset = context.assets_for("styles/home.css").first
  srcset =
    SmokedFish
      .variants
      .map { |variant| "#{variant.src} #{variant.descriptor}" }
      .join(", ")

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
            <main class="#{Styles.fetch("title")}">
              <h1>Hello from #{Shared::NAME}</h1>
              <p>#{Shared::TAGLINE}</p>
              <figure class="#{Styles.fetch("figure")}">
                <img
                  class="#{Styles.fetch("image")}"
                  src="#{SmokedFish.src}"
                  #{%(srcset="#{srcset}") unless srcset.empty?}
                  sizes="(max-width: 720px) 90vw, 640px"
                  width="#{SmokedFish.width}"
                  height="#{SmokedFish.height}"
                  alt="Smoked fish"
                >
                <figcaption class="#{Styles.fetch("caption")}">Image imported through Klenod with generated variants.</figcaption>
              </figure>
              <p>Served through async-http and reloaded through Klenod watch events.</p>
            </main>
          </body>
        </html>
      HTML
    ]
  ]
end
