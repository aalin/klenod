# frozen_string_literal: true

NAME = "Alpha"

def self.describe
  "#{NAME} from box #{Ruby::Box.current.object_id}"
end

def self.greet(name)
  "#{NAME} says hello to #{name}"
end
