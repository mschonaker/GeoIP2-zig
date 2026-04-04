---
name: geoip-run
description: Run the geoip-zig binary in the background, check status, smoketest endpoints, and stop it. Useful for testing local deployments.
license: Apache-2.0
compatibility: opencode
metadata:
  audience: developers
  workflow: local-binary-management
---

## What I do

- **Run in background**: Start `./zig-out/bin/geoip-zig` in background with output discarded
- **Smoketest**: Test API endpoints and verify valid JSON responses
- **Check status**: Show if the binary is running and its PIDs
- **Stop**: Kill all running instances of geoip-zig

## When to use me

Use this skill when:
- You need to run the geoip-zig binary for testing
- You want to run it in background while doing other work
- You need to verify the API is working (smoketest)
- You need to stop running instances

## Core Commands

### Run in background
```bash
./zig-out/bin/geoip-zig > /dev/null 2>&1 &
```

### Check if running
```bash
pgrep geoip-zig
```

### Smoketest (run, test, stop)
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

### Stop all instances
```bash
pkill geoip-zig
```

## Examples

```bash
# Full smoketest workflow
./zig-out/bin/geoip-zig > /dev/null 2>&1 &
sleep 1
curl -s http://127.0.0.1:8080/ipv4/8.8.8.8
pkill geoip-zig
```

## API Endpoints

- `GET /ipv4/<ip>` - Lookup IPv4 address
- `GET /ipv6/<ip>` - Lookup IPv6 address

Returns valid JSON with geolocation data.