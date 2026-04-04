const std = @import("std");
const print = std.debug.print;

const GEOLITE2_CITY_URL = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&suffix=tar.gz";
const OUTPUT_PATH = "src/GeoLite2-City.mmdb";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get license key from environment or GeoIP.conf
    const license_key = blk: {
        // First try environment variable
        if (std.posix.getenv("MAXMIND_LICENSE_KEY")) |key| {
            print("Using license key from MAXMIND_LICENSE_KEY env var\n", .{});
            break :blk key;
        }

        // Try reading from GeoIP.conf
        if (std.fs.cwd().openFile("GeoIP.conf", .{})) |conf_file| {
            defer conf_file.close();
            const contents = conf_file.readToEndAlloc(allocator, 4096) catch null;
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
        std.posix.exit(1);
    };

    // Build URL with license key
    const url = try std.fmt.allocPrint(allocator, "{s}&license_key={s}", .{ GEOLITE2_CITY_URL, license_key });
    defer allocator.free(url);

    print("Downloading GeoLite2-City database from MaxMind...\n", .{});

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Download to temp file
    const temp_path = "temp_download.tar.gz";
    const file = try std.fs.cwd().createFile(temp_path, .{});
    var file_writer = file.writer(&.{});
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
    });

    if (result.status != .ok) {
        print("Error: HTTP request failed with status: {}\n", .{result.status});
        print("Make sure your MAXMIND_LICENSE_KEY is valid.\n", .{});
        std.posix.exit(1);
    }

    const file_size = try file.getEndPos();
    print("Downloaded {} bytes\n", .{file_size});

    // Close file and reopen for reading
    file.close();

    // Read the downloaded file
    const input_file = try std.fs.cwd().openFile(temp_path, .{});
    defer input_file.close();

    const data = try input_file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB max
    defer allocator.free(data);

    // Extract .mmdb from tar.gz
    print("Extracting GeoLite2-City.mmdb...\n", .{});
    try extractMmdbFromTarGz(allocator, data, OUTPUT_PATH);

    // Clean up temp file
    std.fs.cwd().deleteFile(temp_path) catch {};

    print("Successfully saved to {s}\n", .{OUTPUT_PATH});
}

fn extractMmdbFromTarGz(allocator: std.mem.Allocator, data: []const u8, output_path: []const u8) !void {
    // Decompress gzip using the new flate API
    var input_reader = std.io.Reader.fixed(data);
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
            const out_file = try std.fs.cwd().createFile(output_path, .{});
            defer out_file.close();
            try out_file.writeAll(mmdb_data);

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
