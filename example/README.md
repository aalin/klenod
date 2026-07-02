# Klenod Example

This example exercises the current Ruby-only module graph.

Run it from the repository root:

```sh
bundle exec ruby example/run.rb
```

It loads `src/pages/home.rb`, resolves its `import("../shared")`, evaluates both files as `Klenod::Runtime::Mod` instances, and prints exported constants from the entrypoint.
