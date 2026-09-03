# frozen_string_literal: true

Router = import("virtual:router")
Root = import("/root.haml")
ROUTE_TRANSLATIONS = {
  "en" => import("/routes.intl.en.toml"),
  "sv" => import("/routes.intl.sv.toml")
}
App = Example::Framework::RouterApp.new(
  root: Root,
  root_module_id: "app:/root.haml",
  router: Router::Default,
  translations: ROUTE_TRANSLATIONS,
  default_locale: "en"
)

def self.call(raw_request, context)
  App.call(raw_request, context)
end

def self.module_path
  __FILE__
end
