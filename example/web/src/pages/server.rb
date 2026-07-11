# frozen_string_literal: true

Router = import("virtual:router")

def self.call(request, context)
  match = Router::Default.match(request&.path || "/")
  return [404, {"content-type" => "text/plain"}, ["Not found\n"]] unless match
  return call_route_handler(match.handler, request, context) if match.handler

  page = match.page
  body =
    page
      .new(params: match.params)
      .render
  body =
    match
      .layouts
      .reverse_each
      .reduce(body) do |inner, layout|
        layout.new(children: [inner], slots: render_slots(match, layout)).render
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
          #{body}
        </html>
      HTML
    ]
  ]
end

def self.module_path
  __FILE__
end

def self.call_route_handler(handler, request, context)
  method_name = request_method(request)
  return [405, {"content-type" => "text/plain"}, ["Method not allowed\n"]] unless handler.method_defined?(method_name)

  normalize_response(handler.new.public_send(method_name, request, context))
end

def self.request_method(request)
  method =
    if request
      method_reader = request.method(:method)
      method_reader.call if method_reader.arity == 0
    end
  method.to_s.empty? ? "GET" : method.to_s.upcase
end

def self.normalize_response(response)
  return response if response.is_a?(Array) && response.length == 3
  return [204, {}, []] if response.nil?

  [200, {"content-type" => "text/plain; charset=utf-8"}, [response.to_s]]
end

def self.render_slots(match, layout)
  match
    .slots
    .select { |_name, slot_match| slot_for_layout?(slot_match, layout) }
    .to_h do |name, slot_match|
    [
      name,
      [
        slot_match
          .page
          .new(params: slot_match.params)
          .render
      ]
    ]
  end
end

def self.slot_for_layout?(slot_match, layout)
  slot_match.layout_module_id && layout.module_path.end_with?(slot_match.layout_module_id)
end
