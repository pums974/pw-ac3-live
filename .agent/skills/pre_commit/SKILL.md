---
name: pre_commit
description: Standardized pre-commit workflow for linting, formatting, and local quality gates.
---

# Pre-commit Skill

This skill defines the standard `pre-commit` workflow for `pw-ac3-live`.

## Core Commands

### 1. Run all hooks on demand
Run the full hook suite on all tracked files.
```bash
UV_CACHE_DIR=/tmp/uv-cache uvx pre-commit run -a
```

### 2. Run one hook during debugging
Use this when a single hook fails and you want fast iteration.
```bash
UV_CACHE_DIR=/tmp/uv-cache uvx pre-commit run <hook-id> -a
```

## Hook Coverage in This Project

- File hygiene: trailing whitespace, EOF, line endings, merge/case conflicts, large files.
- Config validation: YAML, TOML, JSON.
- Shell scripts: `shfmt` and `shellcheck`.
- Rust: `cargo fmt`, `cargo clippy -D warnings`, `cargo test` (pre-push).

## Practical Notes

- If `uvx` cache permission fails in restricted environments, set `UV_CACHE_DIR=/tmp/uv-cache`.
- `check-shebang-scripts-are-executable` uses the executable bit from Git index; set it with:
```bash
git add --chmod=+x <script>
```

