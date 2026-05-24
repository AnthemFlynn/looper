# Vendored third-party libraries

Each subdirectory here is a vendored copy of a third-party Zig library.
Source is committed to the repo so builds are fully offline and air-gappable
— there is no fetch step at build time and no Zig package-manager hash to
drift. Updates are made by replacing the subtree wholesale and rerunning
tests.

Each library is wired into `build.zig` as a named module so importers
write `@import("<name>")` rather than relative paths into this directory.
That keeps `vendor/` an implementation detail of the build, not a path
that leaks into source.

---

## kairoz

- **Upstream:** <https://github.com/AnthemFlynn/Kairoz>
- **Vendored version:** v0.3.0
- **License:** MIT — see [kairoz/LICENSE](kairoz/LICENSE)
- **Module name in `build.zig`:** `kairoz`
- **Purpose:** Natural-language temporal expression parsing used by
  `looper once` for inputs like `"in 5 min"` or `"tomorrow at 8am"`.

### To update

1. Clone the upstream tag you want at a temp path.
2. Replace `vendor/kairoz/` with the upstream sources (the root.zig and
   sibling `.zig` files plus the LICENSE). Preserve the layout: `root.zig`
   stays at the top of `vendor/kairoz/`.
3. Bump the **Vendored version** line above to match the upstream tag.
4. Run `zig build test` and `make itest`.
5. Commit as `vendor: Kairoz vX.Y.Z`.
