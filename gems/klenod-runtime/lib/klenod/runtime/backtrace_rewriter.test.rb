# frozen_string_literal: true

#
# Copyright Andrés Alin <andreas.alin@gmail.com>
# License: AGPL-3.0

require "minitest/autorun"

require_relative "backtrace_rewriter"
require_relative "source_map"

class Klenod::Runtime::BacktraceRewriter::Test < Minitest::Test
  BacktraceRewriter = Klenod::Runtime::BacktraceRewriter
  SourceMap = Klenod::Runtime::SourceMap

  FakeMod = Data.define(:source_map, :path, :constant_name)

  def test_rewrite_exception
    source_map = SourceMap::SourceMap.parse(<<~INPUT, <<~OUTPUT)
      :ruby
        def hello
          raise "asd"
        end
      %div
        %p= hello
    INPUT
      class MyComponent
        # #{SourceMap::Mark[2]}
        def hello
          # #{SourceMap::Mark[3]}
          raise "asd"
        end
        def render
          H[:div,
            H[:p
              # #{SourceMap::Mark[6]}
              hello
            ]
          ]
        end
      end
    OUTPUT

    expected = <<~BACKTRACE.lines.map(&:strip)
      /app/components/MyComponent.haml:3:in 'render'
      /app/components/MyComponent.haml:6:in 'render'
      /vendor/klenod/hello.rb:123:in 'update'
    BACKTRACE

    backtrace_rewriter =
      BacktraceRewriter.new(
        {"/app/components/MyComponent.haml" => fake_mod(source_map)}
      )

    actual =
      backtrace_rewriter.rewrite_backtrace(<<~BACKTRACE.lines.map(&:strip))
        /app/components/MyComponent.haml:5:in 'render'
        /app/components/MyComponent.haml:11:in 'render'
        /vendor/klenod/hello.rb:123:in 'update'
      BACKTRACE

    assert_equal(expected, actual)
  end

  def test_source_for_returns_the_original_source_of_a_module
    source_map = SourceMap::SourceMap.parse("%p= x\n", "# #{SourceMap::Mark[1]}\nx\n")
    rewriter = BacktraceRewriter.new({"/app/page.haml" => fake_mod(source_map)})

    assert_equal("%p= x\n", rewriter.source_for("/app/page.haml"))
    assert_nil(rewriter.source_for("/app/other.rb"))
  end

  def test_rewrite_exception_rewrites_generated_constant_paths
    source_map = SourceMap::SourceMap.parse(<<~INPUT, <<~OUTPUT)
      %p= x
    INPUT
      class Page
        def render
          # #{SourceMap::Mark[1]}
          H[:p, x]
        end
      end
    OUTPUT
    constant_name = "Mod_101b82598ea9cbb7174d556e"
    message =
      "undefined local variable or method 'x' for an instance of " \
      "Klenod::Runtime::Generated::#{constant_name}::Exports::Page"
    error = NameError.new(message)
    error.set_backtrace(
      [
        "/app/routes/demo/error/+page.haml:4:in 'Klenod::Runtime::Generated::#{constant_name}::Exports::Page#render'"
      ]
    )

    BacktraceRewriter
      .new(
        {
          "routes/demo/error/+page.haml" =>
            fake_mod(
              source_map,
              path: "routes/demo/error/+page.haml",
              constant_name: constant_name
            )
        }
      )
      .rewrite_exception(error)

    assert_includes(error.message, "Mod[\"routes/demo/error/+page.haml\"]::Exports::Page")
    assert_includes(error.to_s, "Mod[\"routes/demo/error/+page.haml\"]::Exports::Page")
    assert_includes(error.backtrace.first, "Mod[\"routes/demo/error/+page.haml\"]::Exports::Page#render")
    refute_includes(error.backtrace.join, "Klenod::Runtime::Generated::#{constant_name}")
  end

  private

  def fake_mod(source_map, path: "/app/components/MyComponent.haml", constant_name: "Mod_000000000000000000000000")
    FakeMod.new(source_map, path, constant_name)
  end
end
