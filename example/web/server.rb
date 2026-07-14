# frozen_string_literal: true

require_relative "server/app"

Example::DevServer.new(config_path: File.expand_path("klenod.config.rb", __dir__)).run
