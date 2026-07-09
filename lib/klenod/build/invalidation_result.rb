# frozen_string_literal: true

module Klenod
  module Build
    AssetUpdate = Data.define(:output_path, :previous_asset, :current_asset) do
      def added?
        previous_asset.nil? && !current_asset.nil?
      end

      def changed?
        !previous_asset.nil? && !current_asset.nil?
      end

      def removed?
        !previous_asset.nil? && current_asset.nil?
      end
    end

    AssetChanges = Data.define(:added, :changed, :removed) do
      def empty?
        added.empty? && changed.empty? && removed.empty?
      end

      def paths
        (added + changed + removed).uniq
      end
    end

    InvalidationResult =
      Data.define(
        :changed_module_ids,
        :removed_module_ids,
        :reloaded_module_ids,
        :reevaluated_module_ids,
        :added_assets,
        :changed_assets,
        :removed_assets,
        :asset_updates,
        :errors
      ) do
        def asset_changes
          AssetChanges.new(added_assets, changed_assets, removed_assets)
        end

        def empty?
          changed_module_ids.empty? &&
            removed_module_ids.empty? &&
            reloaded_module_ids.empty? &&
            reevaluated_module_ids.empty? &&
            asset_changes.empty? &&
            errors.empty?
        end
      end
  end
end
