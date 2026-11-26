# Vendored libgit2

`libgit2/` is the part of upstream's tree that its CMake build compiles on macOS for the
configuration in `macapp/Scripts/vendor-libgit2.sh`, unmodified, except for the two
headers CMake would generate, which that script renders from upstream's templates:
`src/util/git2_features.h` (not in upstream's tree) and `include/git2/experimental.h`
(replacing the copy upstream's tree carries).
**Do not edit these files by hand.** Refresh with `macapp/Scripts/vendor-libgit2.sh`.

- Version: `v1.9.7`
- Commit: `49e408b3208bc3093757a1c2db938d3590f3f412`
- Source: https://github.com/libgit2/libgit2/tree/v1.9.7
- Tree SHA-256: `0feb5c0b582792d8d68d8ee749cd0c44061fa23a97037b069050de2cd51ff122`
