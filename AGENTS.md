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

## Push Rule

**Always run tests before pushing**: Before running `git push`, always run `./run_tests.sh` first. Only push if all tests pass.

## Bug Reports

When a bug is found:
1. Add a test case in `tests/` that reproduces the bug
2. Fix the bug
3. Ensure the test passes before pushing
4. Example: localhost (127.0.0.1 / ::1) not in database returns 404