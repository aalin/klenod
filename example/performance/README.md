# Klenod Performance Example

This example generates deterministic large projects outside the repository tree
and builds them through the normal Klenod build path.

Generate the default web-shaped 1k component case:

```sh
bin/generate
```

Generate the 5k component case:

```sh
bin/generate web-5k
```

Build it:

```sh
bin/build
```

Build progress is logged at coarse phases and every 500 collected modules.
Set `KLENOD_PROGRESS_INTERVAL=1000` to change the module interval, or `0` to
hide intermediate module progress.

Measure startup:

```sh
bin/startup
```

The startup command reports both first-entrypoint evaluation and full
entrypoint-reachable preload timings.

Enable detailed Haml transform buckets:

```sh
KLENOD_PROFILE=haml_detail bin/build
```

Generated cases live under `tmp/cases`, which is ignored by git.
Re-running `bin/generate <case>` recreates that case directory from scratch.

To profile the build with Vernier:

```sh
bundle exec vernier run -- bin/build
```

The generated case includes Haml components, companion CSS files, route pages,
layouts, and the router plugin. It intentionally avoids raster image work for
now so the first benchmark focuses on graph collection, Haml/CSS transforms,
asset emission, and bundle writing.
