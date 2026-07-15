# frozen_string_literal: true

require_relative "../rack/asset_app"

module Klenod
  module HTTP
    Response = Klenod::Rack::Response
    AssetApp = Klenod::Rack::AssetApp
  end
end
