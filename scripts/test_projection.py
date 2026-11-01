#!/usr/bin/env python3
"""Differential test for the "?f=" field projection.

Runs the server, requests many projections, and compares each response
with a reference implementation of the projection semantics in Python.
Also checks malformed specs, the path limits, and backward compatibility.

Run from the repository root with the server stopped:

    uv run scripts/test_projection.py [seed]
"""

import json
import random
import string
import subprocess
import sys
import time

BASE = "http://127.0.0.1:8080"
MAX_PATHS = 32
MAX_SEGMENTS = 8
MAX_SEGMENT_BYTES = 64
SPECIALS = set(".,()!*!&=%+ ")

IPV4_ENDPOINTS = [
    "/ipv4/8.8.8.8",
    "/ipv4/1.1.1.1",
    "/ipv4/94.140.14.14",
    "/ipv4/1.0.1.1",
]
IPV6_ENDPOINTS = ["/ipv6/2001:4860:4860::8888"]

WORDS = [
    "continent", "country", "registered_country", "location", "city",
    "code", "geoname_id", "names", "iso_code", "accuracy_radius",
    "latitude", "longitude", "time_zone", "en", "de", "es", "pt-BR",
    "zh-CN", "*", "0", "1", "zz", "nope", "accuracy",
]

failures = []


def curl(url):
    r = subprocess.run(
        ["curl", "-s", "--max-time", "10", "-w", "\n%{http_code}", url],
        capture_output=True, text=True, check=True,
    )
    status = int(r.stdout.rsplit("\n", 1)[1])
    body = r.stdout[: -(len(str(status)) + 1)]
    return status, body


# --- reference projection semantics ---

def split_top(spec):
    parts, cur, in_group = [], "", False
    for c in spec:
        if c == "(":
            in_group = True
        elif c == ")":
            in_group = False
        elif c == "," and not in_group:
            parts.append(cur)
            cur = ""
            continue
        cur += c
    parts.append(cur)
    return parts


def parse(spec):
    paths = []
    for raw in split_top(spec):
        exclude = raw.startswith("!")
        if exclude:
            raw = raw[1:]
        if not raw:
            raise ValueError(spec)
        parts = raw.split(".")
        prefix, last = parts[:-1], parts[-1]
        if len(parts) > MAX_SEGMENTS:
            raise ValueError(spec)
        for seg in prefix:
            check_segment(seg)
        if last.startswith("("):
            if not last.endswith(")") or len(prefix) == 0:
                raise ValueError(spec)
            for name in last[1:-1].split(","):
                check_segment(name)
                paths.append((exclude, prefix + [name]))
        else:
            check_segment(last)
            paths.append((exclude, prefix + [last]))
    return paths


def check_segment(seg):
    if not seg or len(seg) > MAX_SEGMENT_BYTES:
        raise ValueError(seg)
    if seg == "*":
        return
    if any(c in SPECIALS or ord(c) < 0x20 or ord(c) >= 0x7F for c in seg):
        raise ValueError(seg)


def seg_match(seg, child):
    if seg == "*":
        return True
    if isinstance(child, int):
        return child == to_int(seg)
    return seg == child


def to_int(seg):
    try:
        return int(seg)
    except ValueError:
        return None


def value_is_container(value):
    return isinstance(value, (dict, list))


def project(value, paths):
    whole = not any(not ex for ex, _ in paths)
    if not value_is_container(value):
        return value if whole else "null"
    out, _ = filtered(value, paths, 0, whole)
    return out


def filtered(container, paths, depth, whole):
    out = {} if isinstance(container, dict) else []
    children = container.items() if isinstance(container, dict) else enumerate(container)
    for key, child in children:
        sub, ok = select(child, key, paths, depth, whole)
        if ok:
            if isinstance(out, dict):
                out[key] = sub
            else:
                out.append(sub)
    return out, True


def select(value, key, paths, depth, parent_whole):
    matched = [
        (ex, segs) for ex, segs in paths
        if len(segs) > depth and seg_match(segs[depth], key)
    ]
    suppress = any(ex and len(segs) == depth + 1 for ex, segs in matched)
    inc_term = any(not ex and len(segs) == depth + 1 for ex, segs in matched)
    inc_deep = any(not ex and len(segs) > depth + 1 for ex, segs in matched)
    deep = any(len(segs) > depth + 1 for ex, segs in matched)
    whole = parent_whole or inc_term
    if suppress or (not whole and not inc_deep):
        return None, False
    if not deep:
        return value, True
    if not value_is_container(value):
        return (value, True) if whole else (None, False)
    return filtered(value, matched, depth + 1, whole)


# --- test drivers ---

def spec_case(endpoint, spec):
    status, body = curl(f"{BASE}{endpoint}?f={spec}")
    if status != 200:
        failures.append(f"{endpoint} f={spec}: status {status}, expected 200")
        return
    got = json.loads(body)
    want = project(json.loads(curl(BASE + endpoint)[1]), parse(spec))
    if got != want:
        failures.append(f"{endpoint} f={spec}:\n got  {json.dumps(got)}\n want {json.dumps(want)}")


def expect_status(endpoint, spec, code):
    status, _ = curl(f"{BASE}{endpoint}?f={spec}")
    if status != code:
        failures.append(f"{endpoint} f={spec}: status {status}, expected {code}")


def random_spec(rng):
    n = rng.randint(1, 6)
    paths = []
    for _ in range(n):
        prefix = [rng.choice(WORDS) for _ in range(rng.randint(0, 3))]
        if rng.random() < 0.25 and prefix:
            last = "(" + ",".join(rng.choice(WORDS) for _ in range(rng.randint(1, 3))) + ")"
        else:
            last = rng.choice(WORDS)
        mark = "!" if rng.random() < 0.3 else ""
        paths.append(mark + ".".join(prefix + [last]))
    return ",".join(paths)


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 20261101
    server = subprocess.Popen(
        ["./zig-out/bin/geoip-zig"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(1)
    try:
        for endpoint in IPV4_ENDPOINTS + IPV6_ENDPOINTS:
            spec_case(endpoint, "country.iso_code")
            spec_case(endpoint, "country.names.en,location.(latitude,longitude)")
            spec_case(endpoint, "*.iso_code")
            spec_case(endpoint, "names")
            spec_case(endpoint, "!registered_country,!continent.names")
            spec_case(endpoint, "country,!country.names")
            spec_case(endpoint, "location.time_zone,location")
            spec_case(endpoint, "a,a,!a")
            spec_case(endpoint, "*.names.en")
            spec_case(endpoint, "continent.names.pt-BR")
            spec_case(endpoint, "country.iso_code.en")
            spec_case(endpoint, "country.names.(en,de)")
            spec_case(endpoint, "*.names.*")

        rng = random.Random(seed)
        endpoints = IPV4_ENDPOINTS + IPV6_ENDPOINTS
        for _ in range(300):
            spec_case(rng.choice(endpoints), random_spec(rng))

        bad = ["", ",", "a,", "a..b", ".a", "a.", "!", "!!a", "a!", "a.(b)c",
               "(a,b)", "a.(b,c", "a.(,b)", "a%20b", "a%2Eb.b", "a+b", "a%21b",
               "*" * 65, "x." + "y" * 65, ".".join(["s"] * 9)]
        for spec in bad:
            expect_status("/ipv4/8.8.8.8", spec, 400)

        expect_status("/ipv4/8.8.8.8", ",".join(["a"] * MAX_PATHS), 200)
        expect_status("/ipv4/8.8.8.8", ",".join(["a"] * 33), 400)
        expect_status("/ipv4/8.8.8.8", "a.b.c.d.e.f.g.h", 200)
        expect_status("/ipv4/8.8.8.8", "a.b.c.d.e.f.g.h.i", 400)
        expect_status("/ipv4/8.8.8.8", "a" * MAX_SEGMENT_BYTES, 200)
        expect_status("/ipv4/8.8.8.8", "a" * 65, 400)

        status, _ = curl(f"{BASE}/ipv4/8.8.8.8?fields=country")
        if status != 200 or "continent" not in curl(f"{BASE}/ipv4/8.8.8.8?fields=country")[1]:
            failures.append("unknown parameter must fall back to the full response")
        status, _ = curl(f"{BASE}/ipv4/8.8.8.8?x=1")
        if status != 200:
            failures.append("query without f must keep 200")

        print(f"differential projection test: {len(failures)} failures")
        for f in failures[:20]:
            print(f)
        return 1 if failures else 0
    finally:
        server.terminate()
        server.wait()


if __name__ == "__main__":
    sys.exit(main())
