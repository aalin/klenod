# frozen_string_literal: true

module Klenod
  module Build
    InvalidationResult =
      Data.define(
        :changed_module_ids,
        :removed_module_ids,
        :reloaded_module_ids,
        :reevaluated_module_ids,
        :errors
      ) do
        def empty?
          changed_module_ids.empty? &&
            removed_module_ids.empty? &&
            reloaded_module_ids.empty? &&
            reevaluated_module_ids.empty? &&
            errors.empty?
        end
      end
  end
end
