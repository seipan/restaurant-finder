const std = @import("std");
const http = std.http;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdin = std.io.getStdIn().reader();

    const location = try prompt("場所を入力してください: ", allocator, stdin);
    const genre = try prompt("ジャンルを入力してください: ", allocator, stdin);
    const note = try prompt("備考があれば入力してください（なければEnter）: ", allocator, stdin);

    var envmap = try std.process.getEnvMap(allocator);
    defer envmap.deinit();

    const api_key = envmap.get("OPENAI_API_KEY") orelse {
        std.debug.print("OPENAI_API_KEY が設定されていません。\n", .{});
        return;
    };

    const requestBody = try std.fmt.allocPrint(
        allocator,
        \\{{ "model": "gpt-4", "messages": [
        \\  {{ "role": "system", "content": "あなたは食事処を提案するAIです。" }},
        \\  {{ "role": "user", "content": "場所: {s}\nジャンル: {s}\n備考: {s}" }}
        \\]}}
    ,
        .{ location, genre, note },
    );
    defer allocator.free(requestBody);

    // Authorization ヘッダーの作成
    const authHeader = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(authHeader);

    var headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = authHeader },
    };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    var bufs: [2048]u8 = undefined;

    const uri = try std.Uri.parse("https://api.openai.com/v1/chat/completions");
    var req = try client.open(
        .POST,
        uri,
        .{
            .extra_headers = &headers,
            .server_header_buffer = &bufs,
        },
    );
    defer req.deinit();

    req.transfer_encoding = .chunked;
    try req.send();
    try req.writeAll(requestBody);
    try req.finish();
    try req.wait();

    const res = req.reader();
    const body = try res.readAllAlloc(allocator, 1024 * 1024); // 最大1MBまで読み取る
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const choices = root.object.get("choices") orelse return error.MissingField;
    const first_choice = choices.array.items[0];
    const message = first_choice.object.get("message") orelse return error.MissingField;
    const content = message.object.get("content") orelse return error.MissingField;

    std.debug.print("🍽️ おすすめ: {s}\n", .{content.string});
}

fn prompt(
    msg: []const u8,
    allocator: std.mem.Allocator,
    reader: anytype,
) ![]u8 {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}", .{msg});

    var line_buf: [256]u8 = undefined;
    const input = try reader.readUntilDelimiterOrEof(&line_buf, '\n');
    return allocator.dupe(u8, input orelse "");
}
