# frozen_string_literal: true

Shared = import("../shared")
Styles = import("../styles/home.css")

def self.call(_request, context)
  css_asset = context.assets_for("styles/home.css").first

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
              <p>Served through async-http and reloaded through Klenod watch events.</p>
            </main>
          </body>
        </html>
      HTML
    ]
  ]
end
