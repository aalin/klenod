# klenod-plugin-javascript

JavaScript asset plugin for Klenod.

This plugin emits JavaScript files as content-hashed assets and rewrites local
JavaScript imports to point at the emitted dependency asset paths.

The current implementation supports JavaScript files with static imports,
re-exports, and literal dynamic imports. Bare package imports, TypeScript, JSX,
and npm resolution are intentionally deferred.
