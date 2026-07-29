# frozen_string_literal: true

module Klenod
  module Build
    module Plugins
      module Haml
        module Companions
          private

          def companion_patterns(module_id)
            base = module_id.path.delete_suffix(".haml")

            [
              WatchedPattern.new(module_id, "#{base}.css", :companion_style, {}),
              WatchedPattern.new(module_id, "#{base}.intl.*.toml", :companion_intl, {})
            ]
          end

          def companion_path(module_id, extname)
            ModuleId.new(module_id.path.delete_suffix(".haml") + extname, nil)
          end

          def companion_owner_module_id(path, context)
            relative_path = Pathname.new(path).expand_path.relative_path_from(context.source_dir).to_s
            owner_path =
              if relative_path.end_with?(".css")
                relative_path.delete_suffix(".css") + ".haml"
              elsif relative_path.match?(/\.intl\.[^\/]+\.toml\z/)
                relative_path.sub(/\.intl\.[^\/]+\.toml\z/, ".haml")
              end
            return nil unless owner_path

            owner_id = ModuleId.new(owner_path, nil)
            owner_id if context.absolute_path(owner_id).file?
          end
        end
      end
    end
  end
end
