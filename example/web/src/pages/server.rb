# frozen_string_literal: true

Shared = import("/shared")
Router = import("virtual:router")
SmokedFish = import("./smoked-fish.png?width=320,640&format=png")

def self.call(request, context)
  match = Router::Default.match(request&.path || "/")
  return [404, {"content-type" => "text/plain"}, ["Not found\n"]] unless match

  page = match.page
  body =
    page
      .new(
        name: Shared::NAME,
        tagline: Shared::TAGLINE,
        image: SmokedFish,
        params: match.params
      )
      .render
  body =
    match
      .layouts
      .reverse_each
      .reduce(body) do |inner, layout|
        layout.new(children: [inner], slots: render_slots(match)).render
      end
  css_assets = context.assets_for_module(__FILE__, type: :css)

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

def self.module_path
  __FILE__
end

def self.render_slots(match)
  match.slots.to_h do |name, slot_match|
    [
      name,
      [
        slot_match
          .page
          .new(
            name: Shared::NAME,
            tagline: Shared::TAGLINE,
            image: nil,
            params: slot_match.params
          )
          .render
      ]
    ]
  end
end
