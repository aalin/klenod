// The `npm://*` path mapping in tsconfig.json resolves npm imports for editors
// and `tsc`. It works for packages whose type declarations are ordinary modules,
// such as simplex-noise.
//
// gl-matrix 3.4.4 needs help: its package.json points "types" at a
// "dist/index.d.ts" that it does not ship, and the file it does ship wraps
// everything in `declare module "gl-matrix"`, which is an ambient declaration
// rather than a module. Loading that file registers the ambient module, and the
// alias below points the npm:// specifier at it.
/// <reference path="../node_modules/gl-matrix/index.d.ts" />

declare module "npm://gl-matrix" {
  export * from "gl-matrix";
}
