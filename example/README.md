# Klenod Example

This example exercises the current Ruby-only module graph.

Run it from the repository root:

```sh
bundle exec ruby example/run.rb
bundle exec ruby example/build_and_load.rb
bundle exec ruby example/watch.rb
```

It loads `src/pages/home.rb`, resolves its `import("../shared")`, evaluates both files as `Klenod::Runtime::Mod` instances, and prints exported constants from the entrypoint.

`build_and_load.rb` writes `example/dist/klenod.bundle`, reloads it through the runtime API, and evaluates the entrypoint without using the build graph.

`watch.rb` keeps the process running and prints invalidation events when loaded files under `example/src` change.
