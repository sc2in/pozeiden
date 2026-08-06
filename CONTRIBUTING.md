# Contributing to pozeiden

Thank you for taking the time to contribute. This project is maintained by Star City Security Consulting (SC2, [https://sc2.in](https://sc2.in)) and prefers minimal process, high quality, and secure design.

## Get started

1. Fork the repository.
2. Create a feature branch: `git checkout -b fix/whatever`
3. Build and test locally:

```bash
zig build test
zig build examples   # verify all 17 diagram types still render
```

4. Commit with a clear message and include an issue reference (if any):
   - `feat: add ...`
   - `fix: correct ...`
   - `docs: update ...`

5. Open a pull request from your branch to `main`.

## Development workflow

- Keep PRs focused and small.
- Rebase or merge `main` before final review.
- Include test coverage or update tests for behavior changes.
- Use existing style in Zig code and no trailing whitespace.
- AI-assisted contributions are allowed, but every AI-generated suggestion must be reviewed and approved by a human maintainer before merge. No slop: the final code must be correct, secure, and idiomatic, with all edge cases covered.

## Testing

- Core test suite: `zig build test`
- Render all examples: `zig build examples`
- Fuzz harness (if modifying parsers): `zig build fuzz`
- Benchmarks: `zig build bench`

## Golden-file workflow

`zig build test` compares every `examples/*.mmd` render byte-for-byte against
its committed baseline in `tests/golden/*.svg` — this is the primary
regression gate for renderer changes.

- A pure refactor must leave the goldens untouched; that is the review signal
  that output parity held.
- For an intentional rendering change: inspect the failing diff, run
  `zig build update-golden`, review the regenerated SVGs (the diff should
  contain only your intended change), and commit them — ideally in their own
  commit so the review stays trivial.
- Never regenerate goldens to silence a failure you can't explain.

Adding a diagram type means adding an `examples/<type>.mmd`, an entry in
`golden_test.zig`'s case table (a tripwire test counts them), and the
`example_names` list in `build.zig`.

## Releasing

1. On a branch: `nix run .#bump -- <patch|minor|major>` — stamps
   `build.zig.zon`, rolls the CHANGELOG `[Unreleased]` section into a dated
   release section, and commits. Update the README install URL in the same PR.
2. Open a PR; merge once the `ci-gate` check is green.
3. On main: `git tag v<version> && git push origin v<version>`. The tag run
   re-checks the CHANGELOG and version stamp (`tools/check-release.sh`,
   locally runnable as `nix run .#check-release -- v<version>`), runs the full
   CI matrix, and only then publishes the GitHub release (tarballs +
   SHA256SUMS + SBOM) and FlakeHub.
4. If the `bench-regression` check flags a slowdown: re-run it once (hyperfine
   flakes resolve on re-run); a persistent regression needs a justification in
   the PR or a fix before merging.

The dev shell (`nix develop`) installs the pre-push hook that enforces the
CHANGELOG rule locally, and provides `update-zon` for regenerating the
dependency lock.

## Issues

- Use GitHub issues for bug reports and enhancement ideas.
- Provide a minimal reproduction case (a `.mmd` snippet) and expected vs actual behavior.

## SC2 ideals

- **Security**: avoid introducing unsafe memory models or undefined behavior.
- **Reliability**: prefer stable, well-tested code paths.
- **Simplicity**: keep the public API lean — `render()` and `detectDiagramType()`.

## Release notes

Follow `CHANGELOG.md` conventions; record notable changes at the corresponding version section. A maintainer will adapt as needed.
