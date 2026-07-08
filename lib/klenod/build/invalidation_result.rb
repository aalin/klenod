# frozen_string_literal: true

module Klenod
  module Build
    InvalidationResult =
      Data.define(
        :changed_module_ids,
        :removed_module_ids,
        :reloaded_module_ids,
        :reevaluated_module_ids,
        :added_assets,
        :changed_assets,
        :removed_assets,
        :errors
      ) do
        def empty?
          changed_module_ids.empty? &&
            removed_module_ids.empty? &&
            reloaded_module_ids.empty? &&
            reevaluated_module_ids.empty? &&
            added_assets.empty? &&
            changed_assets.empty? &&
            removed_assets.empty? &&
            errors.empty?
        end
      end
  end
end
