# frozen_string_literal: true

module Klenod
  module Build
    Asset = Data.define(:logical_name, :content_hash, :output_path, :source_path, :bytes, :metadata)
  end
end
