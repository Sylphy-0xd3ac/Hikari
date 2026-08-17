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
const max_ocr_address_space_arg = "--as=2147483648"; // 2 GiB virtual address-space ceiling.

/// RapidOCR 只负责读取已经由 Hikari 下载并限制过的本地临时文件，不能自己按 URL
/// 拉图。这样协议白名单、重定向数、超时、压缩文件大小上限仍只有一份实现。
///
/// PP-OCRv6 small 的检测/识别模型随固定版本的 rapidocr wheel 一起安装；运行时
/// 不下载模型。最长边限制 960，检测候选最多 200，batch=1，ORT 2/1 线程，并由
/// prlimit 把单进程地址空间封在 2 GiB 内。线上 278x52 中文样本在这组参数下
/// 修复了旧 Tesseract 的关键字误识别，同时峰值 RSS 约 162 MiB。
const rapidocr_script =
    \\import json, sys
    \\from rapidocr import RapidOCR
    \\params = {
    \\    "Global.log_level": "error",
    \\    "Global.text_score": 0.55,
    \\    "Global.max_side_len": 960,
    \\    "Global.return_word_box": True,
    \\    "Global.return_single_char_box": True,
    \\    "EngineConfig.onnxruntime.intra_op_num_threads": 2,
    \\    "EngineConfig.onnxruntime.inter_op_num_threads": 1,
    \\    "Det.limit_type": "max",
    \\    "Det.limit_side_len": 960,
    \\    "Det.max_candidates": 200,
    \\    "Cls.cls_batch_num": 1,
    \\    "Rec.rec_batch_num": 1,
    \\}
    \\result = RapidOCR(params=params)(sys.argv[1])
    \\lines = []
    \\if result:
    \\    word_results = result.word_results or ()
    \\    for i, text in enumerate(result.txts):
    \\        chars = []
    \\        if i < len(word_results) and word_results[i]:
    \\            for ch in word_results[i]:
    \\                chars.append({"text": ch[0], "score": float(ch[1]), "box": ch[2]})
    \\        lines.append({
    \\            "text": text,
    \\            "score": float(result.scores[i]),
    \\            "box": result.boxes[i].tolist(),
    \\            "chars": chars,
    \\        })
    \\sys.stdout.write(json.dumps({"lines": lines}, ensure_ascii=False, separators=(",", ":")))
;

const Point = [2]f64;
const Box = [4]Point;

const RawChar = struct {
    text: []const u8,
    score: f64,
    box: Box,
};

const RawLine = struct {
    text: []const u8,
    score: f64,
    box: Box,
    chars: []const RawChar,
};

const RawPayload = struct {
    lines: []const RawLine,
};

const Bounds = struct {
    left: f64,
    right: f64,
    top: f64,
    bottom: f64,

    fn width(self: Bounds) f64 {
        return @max(0, self.right - self.left);
    }

    fn height(self: Bounds) f64 {
        return @max(0, self.bottom - self.top);
    }
};

fn bounds(box: Box) Bounds {
    var out: Bounds = .{
        .left = box[0][0],
        .right = box[0][0],
        .top = box[0][1],
        .bottom = box[0][1],
    };
    for (box[1..]) |point| {
        out.left = @min(out.left, point[0]);
        out.right = @max(out.right, point[0]);
        out.top = @min(out.top, point[1]);
        out.bottom = @max(out.bottom, point[1]);
    }
    return out;
}

fn startsWithOneOf(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| if (std.mem.startsWith(u8, s, prefix)) return true;
    return false;
}

fn endsWithOneOf(s: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| if (std.mem.endsWith(u8, s, suffix)) return true;
    return false;
}

const opening_punctuation = [_][]const u8{ "“", "‘", "（", "(", "[", "【", "《", "「", "『" };
const closing_punctuation = [_][]const u8{ "”", "’", "。", "，", "、", "！", "？", "：", "；", "）", ")", "]", "】", "》", "」", "』", ".", ",", "!", "?", ":", ";" };

fn shouldInsertSpace(previous: []const u8, current: []const u8, gap: f64, height: f64) bool {
    // 普通相邻汉字的字框也可能有 1~2px 缝；只有明显大于字高 15% 的空白才是
    // 原图里的分词空格。生产样本字高约 22px，两处分词 gap 为 5/9px。
    const threshold = @max(2.0, height * 0.15);
    if (gap <= threshold) return false;
    if (startsWithOneOf(current, &closing_punctuation)) return false;
    if (endsWithOneOf(previous, &opening_punctuation)) return false;
    return true;
}

fn appendLineText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), line: RawLine) !void {
    if (line.chars.len == 0) {
        try out.appendSlice(gpa, std.mem.trim(u8, line.text, " \t\r\n"));
        return;
    }

    var previous_text: []const u8 = "";
    var previous_bounds: ?Bounds = null;
    for (line.chars) |ch| {
        const text = std.mem.trim(u8, ch.text, " \t\r\n");
        if (text.len == 0) continue;
        const current_bounds = bounds(ch.box);
        if (previous_bounds) |previous| {
            const gap = current_bounds.left - previous.right;
            const height = @max(previous.height(), current_bounds.height());
            if (shouldInsertSpace(previous_text, text, gap, height)) try out.append(gpa, ' ');
        }
        try out.appendSlice(gpa, text);
        previous_text = text;
        previous_bounds = current_bounds;
    }
}

fn isStandaloneDecoration(text0: []const u8) bool {
    const text = std.mem.trim(u8, text0, " \t\r\n");
    for ([_][]const u8{ "|", "｜", "“", "”", "‘", "’", "-", "—", "_", ".", "·" }) |mark| {
        if (std.mem.eql(u8, text, mark)) return true;
    }
    return false;
}

fn overlapRatioOfSmaller(a: Bounds, b: Bounds) f64 {
    const left = @max(a.left, b.left);
    const right = @min(a.right, b.right);
    const top = @max(a.top, b.top);
    const bottom = @min(a.bottom, b.bottom);
    const overlap = @max(0, right - left) * @max(0, bottom - top);
    const smaller = @min(a.width() * a.height(), b.width() * b.height());
    return if (smaller > 0) overlap / smaller else 0;
}

fn duplicateDecoration(lines: []const RawLine, index: usize) bool {
    const line = lines[index];
    const text = std.mem.trim(u8, line.text, " \t\r\n");
    if (!isStandaloneDecoration(text)) return false;
    const line_bounds = bounds(line.box);
    for (lines, 0..) |other, other_index| {
        if (other_index == index or other.score < line.score) continue;
        if (std.mem.indexOf(u8, other.text, text) == null) continue;
        if (overlapRatioOfSmaller(line_bounds, bounds(other.box)) >= 0.6) return true;
    }
    return false;
}

fn sameVisualLine(a: Bounds, b: Bounds) bool {
    const overlap = @max(0, @min(a.bottom, b.bottom) - @max(a.top, b.top));
    const smaller_height = @min(a.height(), b.height());
    return smaller_height > 0 and overlap / smaller_height >= 0.5;
}

/// 把 RapidOCR 的结构化结果重建为正文。文本框顺序由 RapidOCR 的阅读顺序提供；
/// 同一视觉行的多个框用空格连接，不同行用换行。单字框的几何 gap 再负责恢复
/// 一个识别框内部被模型省略的中文空格。
fn parseRapidOcr(gpa: std.mem.Allocator, json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(RawPayload, gpa, json, .{}) catch return error.OcrFailed;
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var previous_bounds: ?Bounds = null;

    for (parsed.value.lines, 0..) |line, index| {
        if (line.score < 0.55) continue;
        if (std.mem.trim(u8, line.text, " \t\r\n").len == 0) continue;
        if (duplicateDecoration(parsed.value.lines, index)) continue;

        const current_bounds = bounds(line.box);
        if (out.items.len > 0) {
            if (previous_bounds) |previous| {
                try out.append(gpa, if (sameVisualLine(previous, current_bounds)) ' ' else '\n');
            }
        }
        try appendLineText(gpa, &out, line);
        previous_bounds = current_bounds;
    }

    return out.toOwnedSlice(gpa);
}

/// 本地 OCR 不常驻模型：只有候选通过 tombstone/existing/chain-member 且正常
/// 正文为空时，才依次启动 curl 和 RapidOCR。图片很少见，单请求进程让崩溃、
/// 泄漏和超时天然隔离；prlimit/timeout 再给每次识别加硬上限。
pub const Local = struct {
    gpa: std.mem.Allocator,
    python_path: []const u8,
    curl_path: []const u8 = "/usr/bin/curl",
    timeout_path: []const u8 = "/usr/bin/timeout",
    prlimit_path: []const u8 = "/usr/bin/prlimit",

    pub fn init(gpa: std.mem.Allocator, python_path: []const u8) Local {
        return .{ .gpa = gpa, .python_path = python_path };
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
        // Zig 0.15.2 has no statFileAbsolute; Dir.statFile explicitly accepts an
        // absolute sub_path and ignores the directory handle in that case.
        const stat = std.fs.cwd().statFile(image_path) catch return error.DownloadFailed;
        if (stat.size == 0) return error.EmptyImage;
        if (stat.size > max_image_bytes) return error.ImageTooLarge;

        const raw = try self.runRapidOcr(image_path);
        defer self.gpa.free(raw);
        const text = try parseRapidOcr(self.gpa, raw);
        defer self.gpa.free(text);
        return arena.dupe(u8, text);
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

    fn runRapidOcr(self: *Local, image_path: []const u8) ![]u8 {
        var env = try std.process.getEnvMap(self.gpa);
        defer env.deinit();
        try env.put("OMP_NUM_THREADS", "2");
        try env.put("OMP_THREAD_LIMIT", "2");

        const result = std.process.Child.run(.{
            .allocator = self.gpa,
            .argv = &.{
                self.timeout_path,
                "--signal=KILL",
                "20s",
                self.prlimit_path,
                max_ocr_address_space_arg,
                "--cpu=20",
                "--",
                self.python_path,
                "-c",
                rapidocr_script,
                image_path,
            },
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

test "parseRapidOcr：PP-OCRv6 单字框按几何间距恢复中文空格" {
    const gpa = std.testing.allocator;
    const json =
        \\{"lines":[{"text":"“老天爷呀你下屌吧操死我吧”","score":0.9999,"box":[[25,17],[264,19],[263,41],[25,39]],"chars":[
        \\{"text":"“","score":0.99,"box":[[25,17],[37,17],[37,39],[25,39]]},
        \\{"text":"老","score":0.99,"box":[[37,17],[51,17],[51,39],[37,39]]},
        \\{"text":"天","score":0.99,"box":[[51,17],[67,17],[67,39],[51,39]]},
        \\{"text":"爷","score":0.99,"box":[[68,17],[85,17],[85,39],[68,39]]},
        \\{"text":"呀","score":0.99,"box":[[87,17],[104,17],[104,39],[87,39]]},
        \\{"text":"你","score":0.99,"box":[[109,17],[126,17],[126,39],[109,39]]},
        \\{"text":"下","score":0.99,"box":[[127,17],[144,18],[144,40],[127,39]]},
        \\{"text":"屌","score":0.99,"box":[[145,18],[162,18],[161,40],[145,40]]},
        \\{"text":"吧","score":0.99,"box":[[162,18],[177,18],[177,40],[161,40]]},
        \\{"text":"操","score":0.99,"box":[[186,18],[202,18],[202,40],[186,40]]},
        \\{"text":"死","score":0.99,"box":[[202,18],[218,18],[218,40],[202,40]]},
        \\{"text":"我","score":0.99,"box":[[219,18],[236,18],[236,40],[219,40]]},
        \\{"text":"吧","score":0.99,"box":[[237,18],[252,18],[251,40],[237,40]]},
        \\{"text":"”","score":0.99,"box":[[252,18],[264,19],[263,41],[251,40]]}
        \\]}]}
    ;
    const got = try parseRapidOcr(gpa, json);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("“老天爷呀 你下屌吧 操死我吧”", got);
}

test "parseRapidOcr：过滤与正文重叠的单独装饰框，同一视觉行用空格连接" {
    const gpa = std.testing.allocator;
    const json =
        \\{"lines":[
        \\{"text":"“","score":0.85,"box":[[26,19],[38,19],[38,30],[26,30]],"chars":[]},
        \\{"text":"“第一段","score":0.99,"box":[[28,15],[110,16],[110,44],[27,43]],"chars":[]},
        \\{"text":"第二段","score":0.99,"box":[[103,16],[188,16],[188,42],[103,42]],"chars":[]},
        \\{"text":"下一行","score":0.99,"box":[[20,60],[100,60],[100,88],[20,88]],"chars":[]}
        \\]}
    ;
    const got = try parseRapidOcr(gpa, json);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("“第一段 第二段\n下一行", got);
}

test "parseRapidOcr：空结果与低分框不产生正文" {
    const gpa = std.testing.allocator;
    const empty = try parseRapidOcr(gpa, "{\"lines\":[]}");
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const low = try parseRapidOcr(
        gpa,
        "{\"lines\":[{\"text\":\"幻觉\",\"score\":0.2,\"box\":[[0,0],[1,0],[1,1],[0,1]],\"chars\":[]}]}",
    );
    defer gpa.free(low);
    try std.testing.expectEqualStrings("", low);
}

test "parseRapidOcr：坏 JSON 按 OcrFailed 处理" {
    try std.testing.expectError(error.OcrFailed, parseRapidOcr(std.testing.allocator, "not json"));
}
