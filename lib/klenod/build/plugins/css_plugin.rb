# frozen_string_literal: true

require_relative "../plugin"
require_relative "../errors"

module Klenod
  module Build
    module Plugins
      class CssPlugin < Plugin
        def transform(module_id, code, _context)
          return super unless module_id.extname == ".css"

          raise UnsupportedFileError, "CSS transform is not implemented yet for #{module_id}"
        end
      end
    end
  end
end
