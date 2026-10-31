#!/usr/bin/env python3
"""Generate the MMDB fuzz corpus.

The parser rejects databases smaller than 128 KiB, so every synthetic seed is
padded to exactly that size.  Each seed has a valid trie, a 16-byte zero
separator, a data section, the metadata separator, and a metadata map.

Seeds:
  real.mmdb             real GeoLite2-City data behind a 1-node trie
  trie24/28/32.mmdb     multi-node tries for every record size
  types.mmdb            one leaf per data type
  deep.mmdb             250 nested maps
  strings.mmdb          every string length encoding
  metadata_*.mmdb       minimal, full, and empty metadata shapes

Run from the repository root:

    uv run scripts/gen_fuzz_corpus.py
"""

import struct
from pathlib import Path

SEP = b"\xab\xcd\xefMaxMind.com"
TOTAL = 128 * 1024
DATA_WINDOW = 160_000
FIRST_DATA = 0


def ctrl(typ: int, size: int) -> bytes:
    """Encode an MMDB control byte and its size extension."""
    if typ <= 7:
        base = typ << 5
        ext = b""
    else:
        base = 0
        ext = bytes([typ - 7])
    if size <= 28:
        return bytes([base | size]) + ext
    if size <= 284:
        return bytes([base | 29]) + ext + bytes([size - 29])
    if size <= 65820:
        return bytes([base | 30]) + ext + (size - 285).to_bytes(2, "big")
    return bytes([base | 31]) + ext + (size - 65821).to_bytes(3, "big")


def enc_string(value: bytes) -> bytes:
    return ctrl(2, len(value)) + value


def enc_bytes(value: bytes) -> bytes:
    return ctrl(4, len(value)) + value


def enc_uint(typ: int, value: int, width: int) -> bytes:
    size = 0 if value == 0 else (value.bit_length() + 7) // 8
    assert size <= width, (typ, value, width)
    return ctrl(typ, size) + value.to_bytes(size, "big")


def enc_uint16(value: int) -> bytes:
    return enc_uint(5, value, 2)


def enc_uint32(value: int) -> bytes:
    return enc_uint(6, value, 4)


def enc_uint64(value: int) -> bytes:
    return enc_uint(9, value, 8)


def enc_uint128(value: int) -> bytes:
    return enc_uint(10, value, 16)


def enc_int32(value: int) -> bytes:
    return ctrl(8, 4) + struct.pack(">i", value)


def enc_double(value: float) -> bytes:
    return ctrl(3, 8) + struct.pack(">d", value)


def enc_float(value: float) -> bytes:
    return ctrl(15, 4) + struct.pack(">f", value)


def enc_bool(value: bool) -> bytes:
    return ctrl(14, 1 if value else 0)


def enc_map(pairs) -> bytes:
    return ctrl(7, len(pairs)) + b"".join(key + value for key, value in pairs)


def enc_array(values) -> bytes:
    return ctrl(11, len(values)) + b"".join(values)


def enc_pointer(offset: int) -> bytes:
    if offset < 2048:
        return bytes([0x20 | (offset >> 8), offset & 0xFF])
    if offset < 526336:
        value = offset - 2048
        return bytes([0x28 | (value >> 16), (value >> 8) & 0xFF, value & 0xFF])
    if offset < 134744064:
        value = offset - 526336
        return bytes([0x30 | (value >> 24)]) + (value & 0xFFFFFF).to_bytes(3, "big")
    return bytes([0x38]) + offset.to_bytes(4, "big")


def enc_node(record_size: int, left: int, right: int) -> bytes:
    if record_size == 24:
        return left.to_bytes(3, "big") + right.to_bytes(3, "big")
    if record_size == 28:
        return bytes(
            [
                (left >> 16) & 0xFF,
                (left >> 8) & 0xFF,
                left & 0xFF,
                ((left >> 24) & 0x0F) << 4 | ((right >> 24) & 0x0F),
                (right >> 16) & 0xFF,
                (right >> 8) & 0xFF,
                right & 0xFF,
            ]
        )
    if record_size == 32:
        return left.to_bytes(4, "big") + right.to_bytes(4, "big")
    raise ValueError(f"unsupported record size {record_size}")


class DataBuilder:
    """Place data records at fixed offsets in a zero-filled data section."""

    def __init__(self):
        self.buf = bytearray(TOTAL)
        self.spans = []

    def put(self, offset: int, blob: bytes) -> None:
        end = offset + len(blob)
        assert end <= len(self.buf), f"record at {offset} exceeds the buffer"
        for start, stop in self.spans:
            assert end <= start or offset >= stop, f"record at {offset} overlaps"
        self.buf[offset:end] = blob
        self.spans.append((offset, end))

    def bytes(self) -> bytes:
        end = max((stop for _, stop in self.spans), default=0)
        return bytes(self.buf[:end])


def full_trie(record_size: int, node_count: int, leaf_records) -> bytes:
    """Encode a complete depth-4 binary tree with 15 nodes."""
    assert node_count == 15
    assert len(leaf_records) == 16
    nodes = []
    for i in range(7):
        nodes.append((2 * i + 1, 2 * i + 2))
    for i in range(8):
        nodes.append((leaf_records[2 * i], leaf_records[2 * i + 1]))
    return b"".join(enc_node(record_size, left, right) for left, right in nodes)


def data_record(node_count: int, offset: int) -> int:
    return node_count + 16 + offset


def build_mmdb(
    record_size: int,
    node_count: int,
    trie: bytes,
    data: bytes,
    metadata: bytes,
    total: int = TOTAL,
) -> bytes:
    node_bytes = node_count * (record_size * 2) // 8
    assert len(trie) == node_bytes, (len(trie), node_bytes)
    data_start = node_bytes + 16
    metadata_offset = total - len(metadata)
    separator_pos = metadata_offset - len(SEP)
    data_len = separator_pos - data_start
    assert data_len >= len(data), (data_len, len(data))

    seed = bytearray(total)
    seed[0:node_bytes] = trie
    seed[data_start : data_start + len(data)] = data
    seed[separator_pos : separator_pos + len(SEP)] = SEP
    seed[metadata_offset:] = metadata

    assert SEP not in seed[:separator_pos], "unexpected separator before metadata"
    return bytes(seed)


def metadata_map(
    node_count: int,
    record_size: int,
    *,
    full: bool = True,
    languages=None,
    description=None,
    ip_version: int = 6,
    build_epoch: int = 1_700_000_000,
    database_type: bytes = b"GeoIP2-zig-test",
) -> bytes:
    languages = [b"en"] if languages is None else languages
    description = {b"en": b"Test database"} if description is None else description
    pairs = [
        (b"binary_format_major_version", enc_uint16(2)),
        (b"binary_format_minor_version", enc_uint16(0)),
        (b"build_epoch", enc_uint64(build_epoch)),
        (b"database_type", enc_string(database_type)),
        (
            b"description",
            enc_map([(enc_string(key), enc_string(value)) for key, value in description.items()]),
        ),
        (b"ip_version", enc_uint16(ip_version)),
        (b"languages", enc_array([enc_string(lang) for lang in languages])),
        (b"node_count", enc_uint32(node_count)),
        (b"record_size", enc_uint16(record_size)),
    ]
    if not full:
        pairs = [pair for pair in pairs if pair[0] in (b"node_count", b"record_size")]
    return enc_map([(enc_string(key), value) for key, value in pairs])


def one_node_seed(record_size: int, data: bytes, metadata: bytes) -> bytes:
    node_count = 1
    trie = enc_node(record_size, data_record(node_count, 0), data_record(node_count, 0))
    return build_mmdb(record_size, node_count, trie, data, metadata)


def real_seed(root: Path) -> bytes:
    db = (root / "src/GeoLite2-City.mmdb").read_bytes()
    sep_at = db.rfind(SEP)
    assert sep_at != -1, "MMDB separator not found"
    real_metadata = db[sep_at + len(SEP) :]
    real_data_start = read_uint(real_metadata, b"node_count") * (
        read_uint(real_metadata, b"record_size") // 4
    ) + 16
    metadata = patch_uint(real_metadata, b"node_count", 1)
    metadata = patch_uint(metadata, b"record_size", 24)

    data = db[real_data_start : real_data_start + DATA_WINDOW]
    assert SEP not in data, "data window contains the metadata separator"

    node_count = 1
    trie = enc_node(24, data_record(node_count, FIRST_DATA), data_record(node_count, FIRST_DATA))
    total = len(trie) + 16 + len(data) + len(SEP) + len(metadata)
    return build_mmdb(24, node_count, trie, data, metadata, total=total)


def trie_data() -> bytes:
    db = DataBuilder()
    db.put(0, enc_string(b"leaf0"))
    db.put(8, enc_uint16(1))
    db.put(16, enc_uint32(2))
    db.put(24, enc_uint64(3))
    db.put(32, enc_uint128(4))
    db.put(40, enc_double(1.5))
    db.put(56, enc_bool(True))
    db.put(
        64,
        enc_array([enc_uint16(1), enc_string(b"two"), enc_bool(True)]),
    )
    db.put(
        96,
        enc_map(
            [
                (enc_string(b"a"), enc_uint16(1)),
                (enc_string(b"b"), enc_string(b"two")),
            ]
        ),
    )
    db.put(128, enc_map([(enc_pointer(160), enc_pointer(8))]))
    db.put(160, enc_string(b"a"))
    db.put(176, enc_string(b"leaf11"))
    db.put(192, enc_string(b"leaf12"))
    db.put(65_536, enc_string(b"far"))
    db.put(100_000, enc_string(b"farther"))
    return db.bytes()


def trie_seed(record_size: int) -> bytes:
    node_count = 15
    offsets = [0, 8, 16, 24, 32, 40, 56, 64, 96, 128, 160, 176, 192, 100_000, 65_536, None]
    leaf_records = [
        node_count if offset is None else data_record(node_count, offset) for offset in offsets
    ]
    trie = full_trie(record_size, node_count, leaf_records)
    metadata = metadata_map(node_count, record_size)
    return build_mmdb(record_size, node_count, trie, trie_data(), metadata)


def types_seed() -> bytes:
    node_count = 15
    values = [
        enc_string(b"hello"),
        enc_uint16(65_535),
        enc_uint32(0xFFFFFFFF),
        enc_uint64(0xFFFFFFFFFFFFFFFF),
        enc_uint128((1 << 128) - 1),
        enc_double(1.5),
        enc_bool(False),
        enc_bool(True),
        enc_bytes(b"\x00\x01\x02"),
        enc_int32(-123_456),
        enc_float(2.5),
        enc_array([enc_string(b"a"), enc_uint16(1)]),
        enc_map([(enc_string(b"nested"), enc_string(b"yes"))]),
        ctrl(12, 0),
        ctrl(13, 0),
    ]
    db = DataBuilder()
    offsets = []
    offset = 0
    for value in values:
        db.put(offset, value)
        offsets.append(offset)
        offset += len(value) + 1
    offsets.append(None)

    leaf_records = [
        node_count if item is None else data_record(node_count, item) for item in offsets
    ]
    trie = full_trie(24, node_count, leaf_records)
    metadata = metadata_map(node_count, 24)
    return build_mmdb(24, node_count, trie, db.bytes(), metadata)


def deep_seed() -> bytes:
    value = enc_string(b"bottom")
    for _ in range(250):
        value = enc_map([(enc_string(b"a"), value)])
    metadata = metadata_map(1, 24)
    return one_node_seed(24, value, metadata)


def strings_seed() -> bytes:
    lengths = [28, 29, 284, 285, 65_821]
    pairs = [(enc_string(f"s{n}".encode()), enc_string(b"a" * n)) for n in lengths]
    metadata = metadata_map(1, 24)
    return one_node_seed(24, enc_map(pairs), metadata)


def metadata_seed(name: str) -> bytes:
    if name == "minimal":
        metadata = metadata_map(1, 24, full=False)
    elif name == "full":
        languages = [f"lang{i:02d}".encode() for i in range(50)]
        description = {f"en{i:02d}".encode(): f"Description {i}".encode() for i in range(20)}
        metadata = metadata_map(1, 24, languages=languages, description=description)
    elif name == "edge":
        metadata = metadata_map(
            1,
            24,
            languages=[],
            description={},
            ip_version=4,
            build_epoch=0,
            database_type=b"",
        )
    else:
        raise ValueError(name)
    return one_node_seed(24, enc_string(b"metadata"), metadata)


def read_uint(metadata: bytes, key: bytes) -> int:
    """Read the big-endian payload of an unsigned int metadata field."""
    key_pos = metadata.index(key)
    assert metadata[key_pos - 1] == 0x40 | len(key), "unexpected key control byte"
    ctrl_pos = key_pos + len(key)
    control = metadata[ctrl_pos]
    typ, size = control >> 5, control & 0x1F
    assert typ in (5, 6), f"unexpected type {typ} for {key!r}"
    return int.from_bytes(metadata[ctrl_pos + 1 : ctrl_pos + 1 + size], "big")


def patch_uint(metadata: bytes, key: bytes, value: int) -> bytes:
    """Rewrite the big-endian payload of an unsigned int metadata field."""
    key_pos = metadata.index(key)
    assert metadata[key_pos - 1] == 0x40 | len(key), "unexpected key control byte"
    ctrl_pos = key_pos + len(key)
    control = metadata[ctrl_pos]
    typ, size = control >> 5, control & 0x1F
    assert typ in (5, 6), f"unexpected type {typ} for {key!r}"
    payload = value.to_bytes(size, "big")
    return metadata[:ctrl_pos] + bytes([control]) + payload + metadata[ctrl_pos + 1 + size :]


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    out_dir = root / "src/mmdb/corpus"
    out_dir.mkdir(parents=True, exist_ok=True)

    seeds = {
        "real.mmdb": real_seed(root),
        "trie24.mmdb": trie_seed(24),
        "trie28.mmdb": trie_seed(28),
        "trie32.mmdb": trie_seed(32),
        "types.mmdb": types_seed(),
        "deep.mmdb": deep_seed(),
        "strings.mmdb": strings_seed(),
        "metadata_minimal.mmdb": metadata_seed("minimal"),
        "metadata_full.mmdb": metadata_seed("full"),
        "metadata_edge.mmdb": metadata_seed("edge"),
    }

    for name, seed in seeds.items():
        assert len(seed) >= TOTAL, (name, len(seed))
        path = out_dir / name
        path.write_bytes(seed)
        print(f"{path}: {len(seed)} bytes")


if __name__ == "__main__":
    main()
