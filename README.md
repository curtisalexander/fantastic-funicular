# aipipe

Fast utilities for AI agent workflows — written in [Zig](https://ziglang.org/), distributed via [uv](https://docs.astral.sh/uv/).

## Install

```bash
# Install from a GitHub Release (once published)
uv tool install aipipe --from "aipipe @ https://github.com/curtisalexander/fantastic-funicular/releases/download/v0.1.0/aipipe-0.1.0-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl"

# Or install from a local wheel
uv tool install aipipe --from ./dist/aipipe-0.1.0-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
```

Pick the wheel matching your platform:

| Platform            | Wheel suffix                                            |
|---------------------|---------------------------------------------------------|
| Linux x86_64        | `manylinux_2_17_x86_64.manylinux2014_x86_64`           |
| Linux aarch64       | `manylinux_2_17_aarch64.manylinux2014_aarch64`         |
| macOS Apple Silicon | `macosx_11_0_arm64`                                    |
| macOS Intel         | `macosx_10_12_x86_64`                                  |
| Windows x86_64      | `win_amd64`                                            |

## Commands

### `aipipe hash`

Content-addressable hashing of files or stdin. Useful for caching LLM responses keyed on input content.

```bash
# xxHash64 (default, extremely fast)
echo "some prompt" | aipipe hash
aipipe hash file1.txt file2.txt

# SHA-256
aipipe hash --sha256 file1.txt
```

### `aipipe fence`

Extract or wrap fenced code blocks from LLM output.

```bash
# Extract all code blocks
cat llm_response.md | aipipe fence

# Extract only Python blocks
cat llm_response.md | aipipe fence --lang python

# Wrap stdin as a fenced block
echo "x = 1" | aipipe fence --wrap --lang python
```

### `aipipe prompt`

Concatenate files into a prompt with file headers and optional token counting.

```bash
# Assemble a prompt from source files
aipipe prompt src/main.zig build.zig

# With token estimate
aipipe prompt -t src/*.zig
```

## How it works

This project uses a pattern similar to how [ruff](https://github.com/astral-sh/ruff) distributes binaries via Python packaging:

1. **Zig binary** is compiled for each target platform in CI
2. **Python wheel** packages the binary in `.data/scripts/` so it lands on `PATH` when installed
3. **Python wrapper** (`python -m aipipe`) finds and exec's the binary
4. **uv** installs the wheel, making `aipipe` available as a command

## Development

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.14+
- [Python](https://www.python.org/) 3.9+

### Build locally

```bash
# Build the Zig binary
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run directly
echo "hello" | ./zig-out/bin/aipipe hash

# Build a wheel for your current platform
python scripts/build_wheel.py
```

### Project structure

```
├── .github/workflows/ci.yml   # CI: build wheels for all platforms
├── build.zig                   # Zig build configuration
├── build.zig.zon               # Zig package manifest
├── src/main.zig                # Zig CLI source
├── python/aipipe/
│   ├── __init__.py             # Package metadata
│   └── __main__.py             # Python wrapper (finds & exec's binary)
├── scripts/build_wheel.py      # Wheel packaging script
└── pyproject.toml              # Python packaging metadata
```

## License

[Apache-2.0](LICENSE)
