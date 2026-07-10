# frozen_string_literal: true

Report = import("./report")

def self.run
  output = Report::Default.call

  if (path = ENV["REPORT_OUTPUT"])
    File.binwrite(path, output)
  else
    puts output
  end
end

Default = method(:run)

Default.call if ENV["KLENOD_STANDALONE_RUN"] || !defined?(Klenod::Build)
