const std = @import("std");
const print = std.debug.print;

const GEOLITE2_CITY_URL = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&suffix=tar.gz";
const OUTPUT_PATH = "src/GeoLite2-City.mmdb";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Get license key from environment or GeoIP.conf
    const license_key = blk: {
        // First try environment variable
        if (init.minimal.environ.getAlloc(allocator, "MAXMIND_LICENSE_KEY")) |key| {
            print("Using license key from MAXMIND_LICENSE_KEY env var\n", .{});
            break :blk key;
        } else |_| {}

        // Try reading from GeoIP.conf
        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(init.io, "GeoIP.conf", .{})) |conf_file| {
            defer conf_file.close(init.io);
            var buf: [4096]u8 = undefined;
            var file_reader = conf_file.reader(init.io, &buf);
            const contents = file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(4096)) catch null;
            if (contents) |data| {
                defer allocator.free(data);
                var lines = std.mem.splitSequence(u8, data, "\n");
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, std.mem.trim(u8, line, &std.ascii.whitespace), "LicenseKey ")) {
                        const key = std.mem.trim(u8, line["LicenseKey ".len..], &std.ascii.whitespace);
                        if (key.len > 0 and !std.mem.eql(u8, key, "YOUR_LICENSE_KEY_HERE")) {
                            print("Using license key from GeoIP.conf\n", .{});
                            break :blk key;
                        }
                    }
                }
            }
        } else |_| {}

        print("Error: No license key found.\n\n", .{});
        print("Either:\n", .{});
        print("  1. Set environment variable: export MAXMIND_LICENSE_KEY=your_key\n", .{});
        print("  2. Edit GeoIP.conf with your LicenseKey\n\n", .{});
        print("Get a free license key at: https://www.maxmind.com/en/geolite2/signup\n", .{});
        std.process.exit(1);
    };

    // Build URL with license key
    const url = try std.fmt.allocPrint(allocator, "{s}&license_key={s}", .{ GEOLITE2_CITY_URL, license_key });
    defer allocator.free(url);

    print("Downloading GeoLite2-City database from MaxMind...\n", .{});

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator, .io = init.io };
    defer client.deinit();

    // Download to temp file
    const temp_path = "temp_download.tar.gz";
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(init.io, temp_path, .{});
    defer file.close(init.io);

    var write_buf: [8192]u8 = undefined;
    var file_writer = file.writer(init.io, &write_buf);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
    });

    if (result.status != .ok) {
        print("Error: HTTP request failed with status: {}\n", .{result.status});
        print("Make sure your MAXMIND_LICENSE_KEY is valid.\n", .{});
        std.process.exit(1);
    }

    try file_writer.interface.flush();
    const file_stat = try file.stat(init.io);
    print("Downloaded {} bytes\n", .{file_stat.size});

    // Read the downloaded file
    const input_file = try cwd.openFile(init.io, temp_path, .{});
    defer input_file.close(init.io);

    var read_buf: [8192]u8 = undefined;
    var file_reader = input_file.reader(init.io, &read_buf);
    const data = try file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(100 * 1024 * 1024)); // 100MB max
    defer allocator.free(data);

    // Extract .mmdb from tar.gz
    print("Extracting GeoLite2-City.mmdb...\n", .{});
    try extractMmdbFromTarGz(allocator, data, OUTPUT_PATH, cwd, init.io);

    // Clean up temp file
    cwd.deleteFile(init.io, temp_path) catch {};

    print("Successfully saved to {s}\n", .{OUTPUT_PATH});
}

fn extractMmdbFromTarGz(allocator: std.mem.Allocator, data: []const u8, output_path: []const u8, cwd: std.Io.Dir, io: std.Io) !void {
    // Decompress gzip
    var input_reader = std.Io.Reader.fixed(data);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input_reader, .gzip, &decompress_buffer);

    // Read decompressed data into a buffer
    const decompressed = try decompressor.reader.allocRemaining(allocator, std.Io.Limit.limited(500 * 1024 * 1024)); // 500MB max
    defer allocator.free(decompressed);

    print("Decompressed to {} bytes\n", .{decompressed.len});

    // Parse tar archive
    var offset: usize = 0;
    while (offset + 512 <= decompressed.len) {
        const header = decompressed[offset .. offset + 512];
        offset += 512;

        // Check for end of archive (all zeros)
        if (std.mem.eql(u8, header[0..100], &[_]u8{0} ** 100)) {
            break;
        }

        // Get filename (offset 0, null-terminated)
        const name_len = std.mem.indexOfScalar(u8, header[0..100], 0) orelse 100;
        const name = header[0..name_len];

        // Check if this is the .mmdb file (ends with GeoLite2-City.mmdb)
        if (std.mem.endsWith(u8, name, "GeoLite2-City.mmdb")) {
            // Get file size from header (offset 124, octal string)
            const size_str = header[124..136];
            const file_size = try parseOctal(size_str);

            print("Found {s} ({} bytes)\n", .{ name, file_size });

            if (offset + file_size > decompressed.len) {
                return error.UnexpectedEndOfData;
            }

            const mmdb_data = decompressed[offset .. offset + file_size];

            // Write to file
            const out_file = try cwd.createFile(io, output_path, .{});
            defer out_file.close(io);

            var write_buf: [8192]u8 = undefined;
            var writer = out_file.writer(io, &write_buf);
            try writer.interface.writeAll(mmdb_data);
            try writer.interface.flush();

            return;
        }

        // Skip to next header (file data is padded to 512-byte blocks)
        const size_str = header[124..136];
        const file_size = try parseOctal(size_str);
        const padded_size = (file_size + 511) & ~@as(usize, 511);
        offset += padded_size;
    }

    return error.MmdbFileNotFound;
}

fn parseOctal(str: []const u8) !usize {
    var result: usize = 0;
    for (str) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') return error.InvalidOctal;
        result = result * 8 + (c - '0');
    }
    return result;
}
