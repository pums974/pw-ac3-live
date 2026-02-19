---
name: research
description: Guidelines for researching technical topics with Context7 and Web Search.
---

# Research Skill

This skill outlines the preferred methods for researching technical topics related to Rust, PipeWire, ALSA, and FFmpeg.

## Tools & Usage

### 1. Context7 (`mcp_context7`)
Use this tool FIRST for specific library documentation and code examples.

- **PipeWire (C)**: `/pipewire/pipewire` (API docs, object model)
- **pipewire-rs**: `/pipewire/pipewire-rs` (Rust PipeWire bindings)
- **ALSA**: `/alsa/alsa-lib` (PCM, mixer, hardware params)
- **FFmpeg (C)**: `/FFmpeg/FFmpeg` (AVCodec, AVFormat contexts)
- **ffmpeg-next**: Search for `ffmpeg-next` (Rust FFmpeg bindings)

**Query Formatting**:
- Be specific: "How to initialize pw_stream for playback" is better than "pipewire stream".

### 2. Web Search (`search_web`)
Use this tool for:
- Troubleshooting specific error messages.
- Understanding high-level concepts not covered in API docs.
- Finding community discussions (GitLab issues, Reddit threads) on similar problems.

## Recommended Workflow

1.  **Analyze the Problem**: Identify the specific library or concept involved.
2.  **Check Context7**: Search for official documentation or examples.
3.  **Fallback to Web**: If Context7 yields insufficient results or if the issue is a specific runtime error, use Web Search.
4.  **Synthesize**: Combine information from multiple sources. Do not blindly copy-paste code without understanding.
