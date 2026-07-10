# frozen_string_literal: true

Report = import("./report")

output = Report::Default.call

if (path = ENV["REPORT_OUTPUT"])
  File.binwrite(path, output)
else
  puts output
end
