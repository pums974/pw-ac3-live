---
name: rust_dev
description: Standardized Rust development workflows for the pw-ac3-live project.
---

# Rust Development Skill

This skill provides standardized commands and practices for developing and verifying Rust code in the `pw-ac3-live` project.

## Core Commands

### 1. Build & Check
Always ensure code compiles and passes static analysis.
```bash
cargo check
cargo clippy -- -D warnings
```

### 2. Formatting
Enforce standard formatting.
```bash
cargo fmt --all
```

### 3. Testing
Run the test suite. Note that some tests require specific audio hardware or PipeWire configurations.
```bash
cargo test
```

### 4. Release Build
For performance testing or actual usage, always use release mode. Debug builds may have audio glitches due to lack of optimization.
```bash
cargo build --release
```

## Critical Constraints

### Real-time Safety (Audio Thread)
In code running within the `process()` callback (the audio thread):
- **NO** memory allocation (vectors, boxing, etc.).
- **NO** mutex locking (use `rtrb` or atomics).
- **NO** I/O (file reading/writing, println!).
- **NO** panics. Use `anyhow` for setup/teardown, but handle runtime errors gracefully (e.g., output silence).

### Error Handling
- Use `anyhow::Result` for functions that can fail during initialization or teardown.
- In the audio thread, swallow errors or log them to a lock-free queue, but do not stop the thread unless critical.
