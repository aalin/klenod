# frozen_string_literal: true

Report = import("./report")

def test_builds_release_report_from_imported_data
  assert_equal(
    <<~REPORT,
      Release Report
      ==============
      Version: 0.2.0
      Completed: 8/11
      Maintainers: Build, Runtime
      Notes: Generated from plain text
    REPORT
    Report::Default.call
  )
end
