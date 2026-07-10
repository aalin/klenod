# frozen_string_literal: true

require_relative "../../lib/klenod"

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
context = config.context
entry = nil
previous_run_flag = ENV["KLENOD_STANDALONE_RUN"]

begin
  ENV["KLENOD_STANDALONE_RUN"] = "1"
  entry = context.entry(config.entrypoints.fetch(0))
ensure
  if previous_run_flag
    ENV["KLENOD_STANDALONE_RUN"] = previous_run_flag
  else
    ENV.delete("KLENOD_STANDALONE_RUN")
  end
end

puts "Loaded #{entry.id}"
puts "Source root: #{config.source_path}"
