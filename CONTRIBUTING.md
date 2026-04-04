# Contributing to GeoIP2-zig

Thank you for your interest in contributing!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/GeoIP2-zig.git`
3. Build the project: `zig build`
4. Run tests: `zig build test`

## Code Style

- Run `zig fmt` before committing
- Comments are welcome when they document public API, explain binary format details, or clarify non-obvious logic
- Use meaningful variable names
- Keep functions focused and small

## Testing

Before pushing, always run:

```shell
./run_tests.sh
```

This runs both unit tests and integration tests via hurl.

## Pull Requests

- Keep PRs focused and reasonably sized
- Include a clear description of changes
- Ensure all tests pass before submitting

## Issues

Feel free to open issues for:
- Bug reports
- Feature requests
- Questions about the implementation