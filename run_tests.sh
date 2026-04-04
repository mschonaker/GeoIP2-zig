#!/bin/bash
# Test runner for GeoIP2-zig

set -e

echo "=== Building ==="
zig build

echo ""
echo "=== Running unit tests ==="
zig build test

echo ""
echo "=== Starting server ==="
./zig-out/bin/geoip-zig > /dev/null 2>&1 &
SERVER_PID=$!
sleep 1

cleanup() {
    echo ""
    echo "=== Stopping server ==="
    kill $SERVER_PID 2>/dev/null || true
    kill $TIMEOUT_PID 2>/dev/null || true
}
trap cleanup EXIT

# Timeout guard: kill server if it hangs for more than 60 seconds
(
    sleep 60
    echo ""
    echo "TIMEOUT: Server or tests did not complete within 60 seconds"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
) &
TIMEOUT_PID=$!

echo "=== Running hurl tests ==="
for f in tests/*.hurl; do
    echo -n "Testing $f... "
    if hurl --json "$f" | jq -e '.success == true' > /dev/null 2>&1; then
        echo "✓ PASSED"
    else
        echo "✗ FAILED"
        exit 1
    fi
done

echo ""
echo "=== All tests passed ==="