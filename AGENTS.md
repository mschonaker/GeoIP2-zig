# GeoIP2-zig Agent Notes

## Running the Binary in Background

```bash
# Run in background (output discarded)
./zig-out/bin/geoip-zig > /dev/null 2>&1 &

# Check if running
pgrep geoip-zig

# Stop all instances
pkill geoip-zig
```

## Smoketest (start, test, stop)

```bash
# Start
./zig-out/bin/geoip-zig > /dev/null 2>&1 &
sleep 1

# Test IPv4 - Google DNS (US)
curl -s http://127.0.0.1:8080/ipv4/8.8.8.8 | jq .

# Test IPv4 - Cloudflare DNS (AU)
curl -s http://127.0.0.1:8080/ipv4/1.1.1.1 | jq .

# Test IPv4 - AdGuard DNS (Cyprus)
curl -s http://127.0.0.1:8080/ipv4/94.140.14.14 | jq .

# Test IPv4 - China
curl -s http://127.0.0.1:8080/ipv4/1.0.1.1 | jq .

# Test IPv6 - Google DNS (US)
curl -s http://127.0.0.1:8080/ipv6/2001:4860:4860::8888 | jq .

# Stop
pkill geoip-zig
```

### Quick Examples with jq

```bash
# Get country name only
curl -s http://127.0.0.1:8080/ipv4/8.8.8.8 | jq -r '.country.names.en'

# Get country + timezone
curl -s http://127.0.0.1:8080/ipv4/8.8.8.8 | jq -r '.country.names.en, .location.time_zone'

# Get city (if available)
curl -s http://127.0.0.1:8080/ipv4/1.0.1.1 | jq -r '.city.names.en // "no city"'
```

## API Endpoints

- `GET /ipv4/<ip>` - Lookup IPv4 address
- `GET /ipv6/<ip>` - Lookup IPv6 address

## Building

```bash
zig build
```

## Useful Commands

- `zig build run` - Build and run
- `zig build test` - Run tests

## Fuzzing the MMDB Parser

The parser has a fuzz target in `src/mmdb/fuzz.zig`. It starts from the valid
seeds in `src/mmdb/corpus/` and mutates them.

```bash
zig build fuzz                # Run the corpus once (smoke test)
zig build fuzz --fuzz=100000  # Run 100,000 fuzz iterations
zig build fuzz --fuzz         # Run forever and open the web UI
```

- The corpus has a real GeoLite2 data window and synthetic seeds. The synthetic
  seeds cover record sizes 24, 28, and 32, every data type, nested maps, deep
  nesting, all string length encodings, and three metadata shapes.
- `MMDBFile.init` rejects databases smaller than 128 KiB. Keep every corpus
  seed at or above 128 KiB.
- `src/mmdb/corpus_test.zig` checks the corpus with `zig build test`. It
  resolves all 16 trie leaves for each record size and checks the type,
  nesting, string, and metadata seeds.
- `--fuzz` without a limit implies `--webui`. Do not combine `--webui` with
  `--fuzz=limit`; the build fails with `limited fuzzing is not implemented yet
  for --webui`.
- A crash is saved to `.zig-cache/f/crash`. This Zig version does not replay it
  automatically, and the file is the raw fuzzer input, not an MMDB file. Add a
  unit test that reproduces the crash, then delete the file and run again.
- Type assertions follow the build mode: Debug builds enable them and release
  builds compile them out. In Debug, malformed input can print `Unexpected type`
  lines. These are expected errors, not crashes.
- Do not set `.fuzz` on the fuzz module in `build.zig`. The build runner
  rebuilds the test binary with `-ffuzz` when `--fuzz` is passed. Setting
  `.fuzz = true` makes the fuzzer segfault at startup.
- Regenerate the corpus after updating `src/GeoLite2-City.mmdb`:

```bash
uv run scripts/gen_fuzz_corpus.py
```

## Push Rule

**Always run tests before pushing**: Before running `git push`, always run `./run_tests.sh` first. Only push if all tests pass.

## Bug Reports

When a bug is found:
1. Add a test case in `tests/` that reproduces the bug
2. Fix the bug
3. Ensure the test passes before pushing
4. Example: localhost (127.0.0.1 / ::1) not in database returns 404