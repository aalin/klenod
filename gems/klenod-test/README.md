# klenod-test

`klenod-test` runs application tests discovered by Klenod's `TestPlugin`. It can
run the full suite once or watch the module graph and rerun only tests related to
a change.

The runner does not choose a testing framework. Applications provide a context
factory and an execution callback:

```ruby
command = Klenod::Test::Command.new(
  ARGV,
  context: -> { build_config.context },
  execute: ->(context, test_paths) { run_tests(context, test_paths) }
)

exit command.call
```

Each batch runs in a fresh worker process. The execution callback receives that
worker's context and sorted source-relative test paths, then returns an integer
exit status. Use `--run` for one run or `--watch` to watch explicitly. Without an
option, the command watches unless `CI` is set.
