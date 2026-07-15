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
