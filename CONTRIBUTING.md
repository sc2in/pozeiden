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

## Issues

- Use GitHub issues for bug reports and enhancement ideas.
- Provide a minimal reproduction case (a `.mmd` snippet) and expected vs actual behavior.

## SC2 ideals

- **Security**: avoid introducing unsafe memory models or undefined behavior.
- **Reliability**: prefer stable, well-tested code paths.
- **Simplicity**: keep the public API lean — `render()` and `detectDiagramType()`.

## Release notes

Follow `CHANGELOG.md` conventions; record notable changes at the corresponding version section. A maintainer will adapt as needed.
