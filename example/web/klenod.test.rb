# frozen_string_literal: true

ENV["KLENOD_EXAMPLE_FAKE_GOOGLE_FONTS"] ||= "1"

require_relative "lib/framework"
require_relative "lib/testing/test_runner"

context { Example::Testing::TestRunner.context }
execute { |test_context, test_paths| Example::Testing::TestRunner.execute(test_context, test_paths) }
format_error { |error, test_context| Example::Testing::TestRunner.format_error(error, test_context) }
