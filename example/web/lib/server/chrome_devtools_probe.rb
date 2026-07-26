# frozen_string_literal: true

require "json"
require "securerandom"

module Example
  class ChromeDevtoolsProbe
    ENDPOINT = "/.well-known/appspecific/com.chrome.devtools.json"

    def initialize(source_dir:, uuid: SecureRandom.uuid)
      @source_dir = source_dir
      @uuid = uuid
    end

    def response_for(request)
      return unless request.path == ENDPOINT

      [
        200,
        {
          "cache-control" => "no-store",
          "content-type" => "application/json; charset=utf-8"
        },
        [JSON.generate({workspace: {root: @source_dir, uuid: @uuid}}), "\n"]
      ]
    end
  end
end
