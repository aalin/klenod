# frozen_string_literal: true

Router = import("virtual:router")

def self.call(raw_request, context)
  match = Router::Default.match(request_path(raw_request))
  return [404, {"content-type" => "text/plain"}, ["Not found\n"]] unless match

  request = Example::Request.from(raw_request, params: match.params)
  return call_route_handler(match.handler, request) if match.handler

  page = match.page
  body =
    page
      .new(request: request)
      .render
  body =
    match
      .layouts
      .reverse_each
      .reduce(body) do |inner, layout|
        layout
          .new(children: [inner], request: request, slots: render_slots(match, layout, request))
          .render
      end
  css_assets = context.assets_for_module(__FILE__, type: :css)

  commit_session(
    Example::Response.html(
      <<~HTML,
        <!doctype html>
        <html>
          <head>
            <title>Klenod example</title>
            #{css_assets.map { |asset| %(<link rel="stylesheet" href="#{asset.output_path}">) }.join("\n")}
          </head>
          #{body}
        </html>
      HTML
      headers: {}
    ),
    request
  ).to_a
end

def self.module_path
  __FILE__
end

def self.request_path(raw_request)
  raw_path = raw_request&.path.to_s
  raw_path = "/" if raw_path.empty?
  raw_path.split("?", 2).fetch(0)
end

def self.call_route_handler(handler, request)
  method_name = request_method(request)
  return Example::Response.text("Method not allowed\n", status: 405).to_a unless handler.method_defined?(method_name)
  return Example::Response.text("Invalid CSRF token\n", status: 403).to_a unless Example::CSRF.valid?(request)

  normalize_response(handler.new.public_send(method_name, request), request)
end

def self.request_method(request)
  method = request&.method
  method.to_s.empty? ? "GET" : method.to_s.upcase
end

def self.normalize_response(response, request)
  return commit_session(response, request).to_a if response.is_a?(Example::Response)
  return response if response.is_a?(Array) && response.length == 3
  return [204, {}, []] if response.nil?

  [200, {"content-type" => "text/plain; charset=utf-8"}, [response.to_s]]
end

def self.commit_session(response, request)
  return response unless request.session.dirty?

  response.with_session(request)
end

def self.render_slots(match, layout, request)
  match
    .slots
    .select { |_name, slot_match| slot_for_layout?(slot_match, layout) }
    .to_h do |name, slot_match|
    [
      name,
      [
        slot_match
          .page
          .new(request: request.with_params(slot_match.params))
          .render
      ]
    ]
  end
end

def self.slot_for_layout?(slot_match, layout)
  slot_match.layout_module_id && layout.module_path.end_with?(slot_match.layout_module_id)
end
