# Klenod Standalone Example

This example uses Klenod without a web framework. It imports JSON, YAML, TOML, and text files, then generates a small release report from a Ruby entrypoint.

Run it from the repository root:

```sh
bundle exec ruby example/standalone/run.rb
```

Build and run it as an executable bundle:

```sh
cd example/standalone
bundle exec klenod build --executable
ruby -I../../lib dist/release_report
```

Once `klenod` is installed as a gem, the generated executable can be run directly with `./dist/release_report`.

The entrypoint writes to `ENV["REPORT_OUTPUT"]` when it is set. Otherwise it prints the report to stdout.

## Tests

Run the integration tests and colocated application tests once:

```sh
cd example/standalone
bundle exec rake test
```

Run the integration tests once, then watch the application tests:

```sh
bundle exec rake test:watch
```

Run only the colocated application tests directly through the Klenod CLI:

```sh
bundle exec klenod test --run
bundle exec klenod test --watch
bundle exec klenod coverage
```

Application tests live under `src` as `*.test.rb`. They are independent test
entrypoints, so they can import application modules but cannot be imported by
application code. Klenod watches each test's dependency graph and reruns only
the tests related to a changed module. The tests use Minitest here, but the
shared runner does not require a particular testing framework.
The small `klenod.test.rb` file connects the runner to Minitest.
The coverage command runs the complete test suite once and reports only the
evaluated application Ruby modules, excluding tests and imported data wrappers.
