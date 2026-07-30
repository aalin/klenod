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
      /app/components/MyComponent.haml:3:in `render'
      /app/components/MyComponent.haml:6:in `render'
      /vendor/klenod/hello.rb:123:in `update'
    BACKTRACE

    backtrace_rewriter =
      BacktraceRewriter.new(
        {"/app/components/MyComponent.haml" => fake_mod(source_map)}
      )

    actual =
      backtrace_rewriter.rewrite_backtrace(<<~BACKTRACE.lines.map(&:strip))
        /app/components/MyComponent.haml:5:in `render'
        /app/components/MyComponent.haml:11:in `render'
        /vendor/klenod/hello.rb:123:in `update'
      BACKTRACE

    assert_equal(expected, actual)
  end

  def test_format_exception
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

    e = StandardError.new("Something went wrong")

    e.set_backtrace(
      [
        "/app/components/MyComponent.haml:3:in `render'",
        "/app/components/MyComponent.haml:6:in `render'",
        "/vendor/klenod/hello.rb:123:in `update'"
      ]
    )

    backtrace_rewriter =
      BacktraceRewriter.new(
        {"/app/components/MyComponent.haml" => fake_mod(source_map)}
      )

    formatted = backtrace_rewriter.format_exception(e)

    assert_includes(formatted, "Something went wrong")
    assert_includes(formatted, "/app/components/MyComponent.haml:2")
  end

  def test_format_exception_omits_sources_section_without_source_maps
    e = StandardError.new("Plain Ruby error")
    e.set_backtrace(["/app/server.rb:12:in `call'"])

    formatted = BacktraceRewriter.new({}).format_exception(e)

    assert_includes(formatted, "Plain Ruby error")
    refute_includes(formatted, "Sources:")
  end

  def test_format_exception_rewrites_generated_constant_paths
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
        "/app/routes/demo/error/+page.haml:4:in `Klenod::Runtime::Generated::#{constant_name}::Exports::Page#render'"
      ]
    )

    formatted =
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
        .format_exception(error)

    assert_includes(error.message, "Mod[\"routes/demo/error/+page.haml\"]::Exports::Page")
    assert_includes(error.to_s, "Mod[\"routes/demo/error/+page.haml\"]::Exports::Page")
    assert_includes(formatted, "Mod[\"routes/demo/error/+page.haml\"]::Exports::Page")
    assert_includes(formatted, "Mod[\"routes/demo/error/+page.haml\"]::Exports::Page#render")
    refute_includes(formatted, "Klenod::Runtime::Generated::#{constant_name}")
  end

  def test_format_exception_keeps_unrecognized_backtrace_lines
    error = StandardError.new("Haml parse error")
    error.set_backtrace(["(haml):21"])

    formatted = BacktraceRewriter.new({}).format_exception(error)

    assert_includes(formatted, "Haml parse error")
    assert_includes(formatted, "from (haml):21")
  end

  def test_format_exception_handles_source_ranges_past_end_of_file
    source_map = SourceMap::SourceMap.parse(<<~INPUT, <<~OUTPUT)
      raise "boom"
    INPUT
      # #{SourceMap::Mark[3]}
      raise "boom"
    OUTPUT
    error = StandardError.new("Boom")
    error.set_backtrace(["/app/page.haml:2:in `render'"])

    formatted = BacktraceRewriter.new({"/app/page.haml" => fake_mod(source_map)}).format_exception(error)

    assert_includes(formatted, "Boom")
    assert_includes(formatted, "/app/page.haml")
    assert_includes(formatted, "  1: raise \"boom\"")
    refute_includes(formatted, "  0:")
  end

  private

  def fake_mod(source_map, path: "/app/components/MyComponent.haml", constant_name: "Mod_000000000000000000000000")
    FakeMod.new(source_map, path, constant_name)
  end
end
