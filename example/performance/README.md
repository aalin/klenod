# Klenod Performance Example

This example generates deterministic large projects outside the repository tree
and builds them through the normal Klenod build path.

Generate the default web-shaped 1k component case:

```sh
bin/generate
```

Build it:

```sh
bin/build
```

The generated case lives in `tmp/cases/web-1k`, which is ignored by git.
Re-running `bin/generate` recreates that directory from scratch.

To profile the build with Vernier:

```sh
bundle exec vernier run -- bin/build
```

The generated case includes Haml components, companion CSS files, route pages,
layouts, and the router plugin. It intentionally avoids raster image work for
now so the first benchmark focuses on graph collection, Haml/CSS transforms,
asset emission, and bundle writing.
