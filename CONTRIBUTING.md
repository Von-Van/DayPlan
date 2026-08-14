# Contributing

Thanks for your interest. This repository is a **portfolio preview** and intentionally focused. Contributions should prioritize clarity, safety, and presentability rather than feature count.

## Guidelines

- Keep PRs small and focused
- Explain intent and tradeoffs in the PR description
- Avoid introducing new dependencies unless necessary
- Update documentation when behavior changes

## Development

- Node.js and Rust versions pinned by `.nvmrc` and `rust-toolchain.toml`
- Ollama with `qwen3:8b` only when exercising the live evaluation harness
- Run `npm ci`, `npm run format:check`, `npm run version:check`, `npm test`, and `npm run build`
- Run `cargo fmt --manifest-path src-tauri/Cargo.toml --check`, `cargo test --manifest-path src-tauri/Cargo.toml`, and `cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings`
- Never commit local databases/logs, planner content, credentials, signing material, model files, or unredacted diagnostics
- Release changes must follow [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md)
