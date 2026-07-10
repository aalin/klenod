# frozen_string_literal: true

Tasks = import("./data/tasks.json")
Owners = import("./data/owners.yaml")
Release = import("./data/release.toml")
Notes = import("./data/notes.txt")

def self.report
  completed = Tasks.fetch("tasks").count { |task| task.fetch("done") }
  total = Tasks.fetch("tasks").length
  maintainers = Owners.fetch("maintainers").join(", ")

  <<~REPORT
    Release Report
    ==============
    Version: #{Release.fetch("release").fetch("version")}
    Completed: #{completed}/#{total}
    Maintainers: #{maintainers}
    Notes: #{Notes.strip}
  REPORT
end

Default = method(:report)
