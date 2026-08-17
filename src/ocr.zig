const std = @import("std");

/// Runner 只依赖这一个很小的接口。生产把它接到 Local，测试可以塞一个不启动
/// 外部进程的桩；这样 OCR 的运行时依赖不会渗进扫描规则本身。
pub const Engine = struct {
    context: *anyopaque,
    recognize_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,

    pub fn recognize(self: Engine, arena: std.mem.Allocator, image_url: []const u8) ![]u8 {
        return self.recognize_fn(self.context, arena, image_url);
    }
};

pub const Error = error{
    InvalidImageUrl,
    DownloadFailed,
    EmptyImage,
    ImageTooLarge,
    OcrFailed,
};

const max_image_bytes: u64 = 16 * 1024 * 1024;
const max_process_output: usize = 1024 * 1024;
const max_ocr_address_space_arg = "--as=2147483648"; // 2 GiB.

/// 本地 OCR 不常驻模型：只有候选通过 tombstone/existing/chain-member 且正常
/// 正文为空时，才依次启动 curl 和 Tesseract。两个 Tesseract pass 也是串行，
/// 所以峰值内存不是二者相加；prlimit/timeout 再给单次识别加硬上限。
pub const Local = struct {
    gpa: std.mem.Allocator,
    tessdata_dir: ?[]const u8,
    curl_path: []const u8 = "/usr/bin/curl",
    timeout_path: []const u8 = "/usr/bin/timeout",
    prlimit_path: []const u8 = "/usr/bin/prlimit",
    tesseract_path: []const u8 = "/usr/bin/tesseract",

    pub fn init(gpa: std.mem.Allocator, tessdata_dir: ?[]const u8) Local {
        return .{ .gpa = gpa, .tessdata_dir = tessdata_dir };
    }

    pub fn engine(self: *Local) Engine {
        return .{ .context = self, .recognize_fn = recognizeErased };
    }

    fn recognizeErased(context: *anyopaque, arena: std.mem.Allocator, image_url: []const u8) ![]u8 {
        const self: *Local = @ptrCast(@alignCast(context));
        return self.recognize(arena, image_url);
    }

    pub fn recognize(self: *Local, arena: std.mem.Allocator, image_url: []const u8) ![]u8 {
        if (!std.mem.startsWith(u8, image_url, "https://") and
            !std.mem.startsWith(u8, image_url, "http://")) return error.InvalidImageUrl;

        var random: [16]u8 = undefined;
        std.crypto.random.bytes(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const image_path = try std.fmt.bufPrint(&path_buf, "/tmp/hikari-ocr-{s}.img", .{hex});

        // O_EXCL + 0600：URL 来自聊天消息，临时图不能落成其它本机用户可读的
        // 固定文件；先占位再让 curl 覆盖，名字也不会与并发/残留任务碰撞。
        const placeholder = try std.fs.createFileAbsolute(image_path, .{
            .exclusive = true,
            .mode = 0o600,
        });
        placeholder.close();
        defer std.fs.deleteFileAbsolute(image_path) catch {};

        try self.download(image_url, image_path);
        const stat = std.fs.cwd().statFile(image_path) catch return error.DownloadFailed;
        if (stat.size == 0) return error.EmptyImage;
        if (stat.size > max_image_bytes) return error.ImageTooLarge;

        var best: ?Candidate = null;
        defer if (best) |*candidate| candidate.deinit(self.gpa);
        var completed_pass = false;

        // PSM 6 适合截图/整块文字；PSM 11 适合表情包上零散的一两行字。
        // 两个布局不能靠消息段提前可靠判断，所以串行各跑一次，再按 TSV 的
        // 字符加权平均 confidence 选择，而不是武断地选“字更多”的噪声结果。
        for ([_][]const u8{ "6", "11" }) |psm| {
            const tsv = self.runTesseract(image_path, psm) catch continue;
            defer self.gpa.free(tsv);
            completed_pass = true;
            var candidate = try parseTsv(self.gpa, tsv);
            if (candidate.text.len == 0) {
                candidate.deinit(self.gpa);
                continue;
            }
            if (best == null or candidate.betterThan(best.?)) {
                if (best) |*old| old.deinit(self.gpa);
                best = candidate;
            } else {
                candidate.deinit(self.gpa);
            }
        }

        if (best) |candidate| return arena.dupe(u8, candidate.text);
        if (!completed_pass) return error.OcrFailed;
        return arena.dupe(u8, "");
    }

    fn download(self: *Local, image_url: []const u8, image_path: []const u8) !void {
        const max_size = comptime std.fmt.comptimePrint("{d}", .{max_image_bytes});
        const result = std.process.Child.run(.{
            .allocator = self.gpa,
            .argv = &.{
                self.timeout_path,
                "--signal=KILL",
                "20s",
                self.curl_path,
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--proto",
                "=http,https",
                "--proto-redir",
                "=http,https",
                "--max-redirs",
                "3",
                "--connect-timeout",
                "5",
                "--max-time",
                "15",
                "--max-filesize",
                max_size,
                "--output",
                image_path,
                image_url,
            },
            .max_output_bytes = 64 * 1024,
        }) catch return error.DownloadFailed;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (!termSucceeded(result.term)) return error.DownloadFailed;
    }

    fn runTesseract(self: *Local, image_path: []const u8, psm: []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{
            self.timeout_path,
            "--signal=KILL",
            "20s",
            self.prlimit_path,
            max_ocr_address_space_arg,
            "--cpu=20",
            "--",
            self.tesseract_path,
            image_path,
            "stdout",
            "-l",
            "chi_sim+eng",
            "--oem",
            "1",
            "--psm",
            psm,
            "--dpi",
            "300",
            "--loglevel",
            "ERROR",
        });
        if (self.tessdata_dir) |dir| try argv.appendSlice(self.gpa, &.{ "--tessdata-dir", dir });
        // Sauvola 对表情包常见的不均匀背景更稳；整块截图的 PSM 6 保留默认
        // Otsu，两个 pass 同时覆盖“干净截图”和“花背景短字”而不常驻第二套模型。
        if (std.mem.eql(u8, psm, "11")) try argv.appendSlice(self.gpa, &.{ "-c", "thresholding_method=2" });
        try argv.append(self.gpa, "tsv");

        var env = try std.process.getEnvMap(self.gpa);
        defer env.deinit();
        try env.put("OMP_THREAD_LIMIT", "2");

        const result = std.process.Child.run(.{
            .allocator = self.gpa,
            .argv = argv.items,
            .env_map = &env,
            .max_output_bytes = max_process_output,
        }) catch return error.OcrFailed;
        defer self.gpa.free(result.stderr);
        if (!termSucceeded(result.term)) {
            self.gpa.free(result.stdout);
            return error.OcrFailed;
        }
        return result.stdout;
    }
};

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

const LineKey = struct {
    page: []const u8,
    block: []const u8,
    paragraph: []const u8,
    line: []const u8,

    fn eql(a: LineKey, b: LineKey) bool {
        return std.mem.eql(u8, a.page, b.page) and
            std.mem.eql(u8, a.block, b.block) and
            std.mem.eql(u8, a.paragraph, b.paragraph) and
            std.mem.eql(u8, a.line, b.line);
    }
};

const Candidate = struct {
    text: []const u8,
    confidence_sum: f64,
    weight: usize,

    fn deinit(self: *Candidate, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        self.* = undefined;
    }

    fn betterThan(self: Candidate, other: Candidate) bool {
        const self_score = self.confidence_sum / @as(f64, @floatFromInt(self.weight));
        const other_score = other.confidence_sum / @as(f64, @floatFromInt(other.weight));
        if (self_score != other_score) return self_score > other_score;
        return self.weight > other.weight;
    }
};

fn asciiWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '\'';
}

fn needsSpace(previous: []const u8, current: []const u8) bool {
    if (previous.len == 0 or current.len == 0) return false;
    return asciiWordByte(previous[previous.len - 1]) and asciiWordByte(current[0]);
}

/// Tesseract TSV 的前 11 列固定，最后一列才是文字。只取 level=5 的 word，
/// 按 page/block/paragraph/line 重建换行；简中 token 之间不凭空加空格，英文
/// 单词之间保留一个空格。负 confidence 是布局节点/拒识，不参与评分。
fn parseTsv(gpa: std.mem.Allocator, tsv: []const u8) !Candidate {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var confidence_sum: f64 = 0;
    var weight: usize = 0;
    var last_key: ?LineKey = null;
    var previous_word: []const u8 = "";

    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |raw0| {
        const raw = std.mem.trimRight(u8, raw0, "\r");
        var fields: [11][]const u8 = undefined;
        var start: usize = 0;
        var ok = true;
        for (&fields) |*field| {
            const rel = std.mem.indexOfScalar(u8, raw[start..], '\t') orelse {
                ok = false;
                break;
            };
            field.* = raw[start .. start + rel];
            start += rel + 1;
        }
        if (!ok or !std.mem.eql(u8, fields[0], "5")) continue;

        const word = std.mem.trim(u8, raw[start..], " \t\r\n");
        if (word.len == 0) continue;
        const confidence = std.fmt.parseFloat(f64, fields[10]) catch continue;
        if (confidence < 0) continue;
        const word_weight = std.unicode.utf8CountCodepoints(word) catch word.len;
        if (word_weight == 0) continue;

        const key: LineKey = .{
            .page = fields[1],
            .block = fields[2],
            .paragraph = fields[3],
            .line = fields[4],
        };
        if (last_key) |last| {
            if (!LineKey.eql(last, key)) {
                try out.append(gpa, '\n');
                previous_word = "";
            } else if (needsSpace(previous_word, word)) {
                try out.append(gpa, ' ');
            }
        }
        try out.appendSlice(gpa, word);
        last_key = key;
        previous_word = word;
        confidence_sum += confidence * @as(f64, @floatFromInt(word_weight));
        weight += word_weight;
    }

    return .{
        .text = try out.toOwnedSlice(gpa),
        .confidence_sum = confidence_sum,
        .weight = weight,
    };
}

test "parseTsv：重建中英混合行并计算字符加权 confidence" {
    const gpa = std.testing.allocator;
    var got = try parseTsv(
        gpa,
        "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n" ++
            "5\t1\t1\t1\t1\t1\t0\t0\t1\t1\t90\t你好\n" ++
            "5\t1\t1\t1\t1\t2\t0\t0\t1\t1\t80\tworld\n" ++
            "5\t1\t1\t1\t2\t1\t0\t0\t1\t1\t70\t第二行\n" ++
            "5\t1\t1\t1\t2\t2\t0\t0\t1\t1\t-1\tignored\n",
    );
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("你好world\n第二行", got.text);
    try std.testing.expectEqual(@as(usize, 10), got.weight);
    try std.testing.expectApproxEqAbs(@as(f64, 79), got.confidence_sum / 10.0, 0.001);
}

test "Candidate：优先平均 confidence，平分时选有效字符更多的一份" {
    const high = Candidate{ .text = "a", .confidence_sum = 90, .weight = 1 };
    const low = Candidate{ .text = "abcdef", .confidence_sum = 480, .weight = 6 };
    try std.testing.expect(high.betterThan(low));

    const long = Candidate{ .text = @constCast("ab"), .confidence_sum = 180, .weight = 2 };
    try std.testing.expect(long.betterThan(high));
}
