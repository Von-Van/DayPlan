# Contributing

Thanks for your interest. This repository is a **portfolio preview** and intentionally focused. Contributions should prioritize clarity, safety, and presentability rather than feature count.

## Guidelines

- Keep PRs small and focused
- Explain intent and tradeoffs in the PR description
- Avoid introducing new dependencies unless necessary
- Update documentation when behavior changes

## Development

- Node.js 24 or newer
- A current Rust toolchain
- Ollama with `qwen3:8b` only when exercising the live evaluation harness
- Run `npm install`, `npm test`, `npm run build`, and `cargo test --manifest-path src-tauri/Cargo.toml`
