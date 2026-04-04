#!/bin/bash
# run_load_tests.sh - Load test runner for geoip-zig

URL="${1:-http://127.0.0.1:8080}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LUA_SCRIPT="$SCRIPT_DIR/mix_ips.lua"

# Detect GitHub Actions environment
IS_CI="${GITHUB_ACTIONS:-false}"

# Terminal colors (suppressed in CI)
if [ "$IS_CI" = "true" ]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

# GitHub Actions workflow commands
gha_group()    { [ "$IS_CI" = "true" ] && echo "::group::$1"; }
gha_endgroup() { [ "$IS_CI" = "true" ] && echo "::endgroup::"; }
gha_notice()   { [ "$IS_CI" = "true" ] && echo "::notice::$1"; }

# Append markdown to the step summary
summary() { [ "$IS_CI" = "true" ] && echo "$1" >> "$GITHUB_STEP_SUMMARY"; }

# Parse wrk output and emit both terminal + summary table row
parse_wrk_output() {
    local test_name="$1"
    local threads="$2"
    local connections="$3"
    local output="$4"

    local rps avg_lat p99_lat transfer
    rps=$(echo "$output"      | grep "Requests/sec:"  | awk '{print $2}')
    avg_lat=$(echo "$output"  | grep "Latency " | grep -v Distribution | awk '{print $2}')
    p99_lat=$(echo "$output"  | grep "^ *99%" | awk '{print $2}')
    transfer=$(echo "$output" | grep "Transfer/sec:"  | awk '{print $2}')

    printf "  ${GREEN}✓${NC} RPS: ${BOLD}%s${NC} | Avg: ${CYAN}%s${NC} | p99: %s | Transfer: %s\n" \
        "$rps" "$avg_lat" "$p99_lat" "$transfer"

    summary "| $test_name | $threads | $connections | **$rps** | $avg_lat | $p99_lat | $transfer |"

    # Announce peak RPS in CI annotations
    if [ "$IS_CI" = "true" ]; then
        gha_notice "$test_name: $rps req/s, avg $avg_lat, p99 $p99_lat"
    fi
}

run_test() {
    local name="$1"
    local threads="$2"
    local connections="$3"
    local duration="$4"

    echo -e "${YELLOW}▶ $name${NC}"
    gha_group "$name (-t$threads -c$connections -d${duration}s)"
    local output
    output=$(wrk -t"$threads" -c"$connections" -d"${duration}s" \
        --latency "$URL/ipv4/8.8.8.8" 2>&1)
    echo "$output"
    gha_endgroup
    parse_wrk_output "$name" "$threads" "$connections" "$output"
}

run_mixed_test() {
    local name="$1"
    local threads="$2"
    local connections="$3"
    local duration="$4"

    echo -e "${YELLOW}▶ $name (mixed IPs)${NC}"
    gha_group "$name: mixed IPs (-t$threads -c$connections -d${duration}s)"
    local output
    output=$(wrk -t"$threads" -c"$connections" -d"${duration}s" \
        --latency -s "$LUA_SCRIPT" "$URL" 2>&1)
    echo "$output"
    gha_endgroup
    parse_wrk_output "$name" "$threads" "$connections" "$output"
}

# Header
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   ${BOLD}GeoIP2-zig Load Tests${NC}                    ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  Target: $URL"
echo "  Time:   $(date '+%H:%M:%S')"
echo ""

if ! curl -s --connect-timeout 2 "$URL/health" > /dev/null 2>&1; then
    echo -e "${RED}✗ Server not running: $URL${NC}"
    echo "  Start: ./zig-out/bin/geoip-zig"
    exit 1
fi
echo -e "${GREEN}✓ Server is up${NC}"
echo ""

# Step summary header
summary "## Load Test Results"
summary ""
summary "| Test | Threads | Connections | RPS | Avg Latency | p99 Latency | Transfer/s |"
summary "|:-----|:-------:|:-----------:|----:|------------:|------------:|-----------:|"

run_test         "Baseline"         1  50  5
run_test         "Concurrent"       2 100  5
run_test         "High Concurrency" 4 200  5
run_mixed_test   "Mixed IPs"        4 100  5
run_test         "Throughput"       8  50  5

echo ""
echo -e "${GREEN}✓ Done${NC}"
echo ""

# Step summary footer
summary ""
summary "> Tested with [wrk](https://github.com/wg/wrk) — 5s per scenario against \`$URL\`"
