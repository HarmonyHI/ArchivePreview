//  压缩包预览器 ArchivePreview v2
//  双击压缩包 → 树形目录查看内容（可切换文件名字符集）→ 自己决定解压什么、解压到哪
//  纯 AppKit 实现（CLT 无 SwiftUI 宏插件，用不了 @State）
//  编译：swiftc -O -o <out> main.swift

import AppKit
import CoreServices

// MARK: - 文件名字符集

enum NameEncoding: Int, CaseIterable {
    case auto, utf8, gb18030, big5, shiftJIS, eucKR, latin1

    var title: String {
        switch self {
        case .auto: return "自动识别"
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030 / GBK（简体）"
        case .big5: return "Big5（繁体）"
        case .shiftJIS: return "Shift-JIS（日文）"
        case .eucKR: return "EUC-KR（韩文）"
        case .latin1: return "Latin-1 / 西欧"
        }
    }

    var swiftEncoding: String.Encoding? {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        switch self {
        case .auto: return nil
        case .utf8: return .utf8
        case .gb18030: return cf(.GB_18030_2000)
        case .big5: return cf(.big5)
        case .shiftJIS: return .shiftJIS
        case .eucKR: return cf(.EUC_KR)
        case .latin1: return .isoLatin1
        }
    }

    /// 传给 libarchive（`--options hdrcharset=`）的字符集名。
    /// 解压必须用和列表显示完全相同的编码，否则文件名会解码成问号或非法字节。
    var archiveCharset: String? {
        switch self {
        case .auto: return nil
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030"
        case .big5: return "BIG5"
        case .shiftJIS: return "CP932"
        case .eucKR: return "EUC-KR"
        case .latin1: return "CP437"
        }
    }
}

/// 根据整个包的条目判定实际编码。
/// 用于把「自动识别」落到一个具体编码上——解压时只能传一个编码，
/// 必须和列表里解码用的是同一个，否则会出现「列表显示正常、解压全是问号」。
func detectEncoding(_ entries: [RawEntry]) -> NameEncoding {
    let sample = Array(entries.prefix(300)).filter { !$0.nameBytes.isEmpty }
    guard !sample.isEmpty else { return .utf8 }

    // 纯 ASCII 名字：什么编码都一样
    if sample.allSatisfy({ $0.nameBytes.allSatisfy { $0 < 0x80 } }) { return .utf8 }

    // 全部条目标了 UTF-8 标志位，直接信它
    if sample.allSatisfy({ $0.utf8Flag }) { return .utf8 }

    // 没标志位但内容是合法 UTF-8（macOS 自己打的包常见这种情况）
    let utf8OK = sample.filter { String(data: $0.nameBytes, encoding: .utf8) != nil }.count
    if Double(utf8OK) >= Double(sample.count) * 0.98 { return .utf8 }

    // 其余情况一律按 GB18030。
    //
    // 这里不做「哪个编码成功率最高」的竞争：GBK 的字节序列在 EUC-KR、Big5 下
    // 往往同样是合法的双字节组合，成功率都是 100%，靠这个根本分不出来
    // （实测一个纯 GBK 的中文包会被误判成 EUC-KR，解出来全是韩文）。
    // 简体中文是绝对主流场景，其余编码交给用户在下拉菜单里手动指定。
    return .gb18030
}

/// 把归档里的原始文件名字节按指定字符集解码
func decodeName(_ data: Data, _ enc: NameEncoding, utf8Flagged: Bool) -> String {
    if utf8Flagged, let s = String(data: data, encoding: .utf8) { return s }
    switch enc {
    case .auto:
        if let s = String(data: data, encoding: .utf8) { return s }
        if let e = NameEncoding.gb18030.swiftEncoding, let s = String(data: data, encoding: e) { return s }
        return String(data: data, encoding: .isoLatin1) ?? "?"
    default:
        if let e = enc.swiftEncoding, let s = String(data: data, encoding: e) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? "?"
    }
}

// MARK: - 原始条目

struct RawEntry {
    var nameBytes: Data
    var size: Int64
    var date: String
    var isDir: Bool
    var utf8Flag: Bool
}

enum ArchiveKind { case zip, tar }

enum ReadError: Error, LocalizedError {
    case notArchive
    case badFormat(String)
    var errorDescription: String? {
        switch self {
        case .notArchive: return "不是可识别的压缩包"
        case .badFormat(let s): return s
        }
    }
}

// MARK: - 通用工具

func runCommand(_ exe: String, _ args: [String]) -> (data: Data, code: Int32) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do { try proc.run() } catch { return (Data(), -1) }
    let handle = pipe.fileHandleForReading
    var buf = Data()
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buf.append(chunk)
    }
    proc.waitUntilExit()
    return (buf, proc.terminationStatus)
}

func sizeString(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    return f.string(fromByteCount: b)
}

func uniqueFolder(_ base: String) -> String {
    let fm = FileManager.default
    if !fm.fileExists(atPath: base) { return base }
    var i = 2
    while fm.fileExists(atPath: "\(base) \(i)") { i += 1 }
    return "\(base) \(i)"
}

let entryLimit = 20000

// MARK: - ZIP 解析（自读中央目录，才能拿到原始文件名字节）

func u16(_ a: [UInt8], _ o: Int) -> Int { Int(a[o]) | (Int(a[o + 1]) << 8) }
func u32(_ a: [UInt8], _ o: Int) -> Int {
    Int(a[o]) | (Int(a[o + 1]) << 8) | (Int(a[o + 2]) << 16) | (Int(a[o + 3]) << 24)
}
func u64(_ a: [UInt8], _ o: Int) -> Int64 {
    var v: Int64 = 0
    for i in (0..<8).reversed() { v = (v << 8) | Int64(a[o + i]) }
    return v
}

func dosDate(_ d: Int, _ t: Int) -> String {
    if d == 0 { return "" }
    let year = ((d >> 9) & 0x7F) + 1980
    let month = (d >> 5) & 0x0F
    let day = d & 0x1F
    let hour = (t >> 11) & 0x1F
    let minute = (t >> 5) & 0x3F
    guard month >= 1, month <= 12, day >= 1, day <= 31 else { return "" }
    return String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
}

func readZipEntries(_ path: String) throws -> [RawEntry] {
    guard let fh = FileHandle(forReadingAtPath: path) else {
        throw ReadError.badFormat("无法打开文件")
    }
    defer { try? fh.close() }
    let fileSize = Int((try? fh.seekToEnd()) ?? 0)
    guard fileSize > 22 else { throw ReadError.notArchive }

    let tailLen = min(fileSize, 66_000)
    try fh.seek(toOffset: UInt64(fileSize - tailLen))
    guard let tailData = try? fh.read(upToCount: tailLen) else { throw ReadError.notArchive }
    let tail = [UInt8](tailData)

    var eocd = -1
    var i = tail.count - 22
    while i >= 0 {
        if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
            eocd = i
            break
        }
        i -= 1
    }
    guard eocd >= 0 else { throw ReadError.notArchive }
    let eocdAbs = Int64(fileSize - tailLen + eocd)

    var total = u16(tail, eocd + 10)
    var cdSize = u32(tail, eocd + 12)
    var cdOffset = Int64(u32(tail, eocd + 16))

    if total == 0xFFFF || cdSize >= 0xFFFFFFFF || cdOffset >= 0xFFFFFFFF {
        let locPos = eocdAbs - 20
        if locPos >= 0 {
            try? fh.seek(toOffset: UInt64(locPos))
            if let d = try? fh.read(upToCount: 20), d.count == 20 {
                let a = [UInt8](d)
                if u32(a, 0) == 0x07064b50 {
                    let z64Pos = u64(a, 8)
                    try? fh.seek(toOffset: UInt64(z64Pos))
                    if let z = try? fh.read(upToCount: 56), z.count >= 56 {
                        let b = [UInt8](z)
                        if u32(b, 0) == 0x06064b50 {
                            total = Int(u64(b, 32))
                            cdSize = Int(u64(b, 40))
                            cdOffset = u64(b, 48)
                        }
                    }
                }
            }
        }
    }
    if cdOffset <= 0 { cdOffset = eocdAbs - Int64(cdSize) }
    guard cdSize > 0, cdSize < 200 * 1024 * 1024 else { throw ReadError.notArchive }

    try fh.seek(toOffset: UInt64(max(0, cdOffset)))
    guard let cdData = try? fh.read(upToCount: cdSize) else { throw ReadError.notArchive }
    let cd = [UInt8](cdData)

    var entries: [RawEntry] = []
    var p = 0
    while p + 46 <= cd.count {
        guard cd[p] == 0x50, cd[p + 1] == 0x4B, cd[p + 2] == 0x01, cd[p + 3] == 0x02 else { break }
        let flags = u16(cd, p + 8)
        let dosT = u16(cd, p + 12)
        let dosD = u16(cd, p + 14)
        var uncomp = Int64(u32(cd, p + 24))
        let nameLen = u16(cd, p + 28)
        let extraLen = u16(cd, p + 30)
        let commentLen = u16(cd, p + 32)
        let extAttr = u32(cd, p + 38)
        let nameStart = p + 46
        guard nameStart + nameLen <= cd.count else { break }
        let nameData = Data(cd[nameStart..<(nameStart + nameLen)])

        if uncomp == 0xFFFFFFFF, extraLen > 0 {
            var q = nameStart + nameLen
            let extraEnd = min(q + extraLen, cd.count)
            while q + 4 <= extraEnd {
                let fid = u16(cd, q)
                let fsz = u16(cd, q + 2)
                if fid == 0x0001, q + 12 <= cd.count {
                    uncomp = u64(cd, q + 4)
                    break
                }
                if fsz == 0 { break }
                q += 4 + fsz
            }
        }

        let utf8Flag = (flags & 0x800) != 0
        let unixMode = (extAttr >> 16) & 0xF000
        let isDir = nameData.last == 0x2F || unixMode == 0x4000 || (extAttr & 0x10) != 0

        entries.append(RawEntry(nameBytes: nameData, size: uncomp,
                                date: dosDate(dosD, dosT), isDir: isDir, utf8Flag: utf8Flag))
        p = nameStart + nameLen + extraLen + commentLen
        if entries.count >= entryLimit { break }
    }
    if entries.isEmpty { throw ReadError.badFormat("中央目录为空或已加密，无法读取") }
    return entries
}

// MARK: - TAR 解析

/// tar -tvf 的时间是 "Nov  1 23:18" 或 "Nov  1  2024"（半年内省略年份），
/// 统一整理成和 zip 一致的 "2026-11-01 23:18"。
func normalizeTarDate(_ month: String, _ day: String, _ timeOrYear: String) -> String {
    let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                  "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    guard let m = months[month.lowercased()],
          let d = Int(day.trimmingCharacters(in: .whitespaces)) else {
        return "\(month) \(day) \(timeOrYear)".trimmingCharacters(in: .whitespaces)
    }
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let year: Int
    let hhmm: String
    if timeOrYear.contains(":") {
        // 只给了时分 → 说明是最近半年内的文件，年份取当前年
        year = cal.component(.year, from: now)
        hhmm = timeOrYear
    } else {
        year = Int(timeOrYear) ?? cal.component(.year, from: now)
        hhmm = "00:00"
    }
    return String(format: "%04d-%02d-%02d %@", year, m, d, hhmm)
}

func readTarEntries(_ path: String) throws -> [RawEntry] {
    let r = runCommand("/usr/bin/tar", ["-tvf", path])
    guard !r.data.isEmpty else { throw ReadError.badFormat("tar 读取失败") }
    var entries: [RawEntry] = []
    for lineSlice in r.data.split(separator: 0x0A, omittingEmptySubsequences: true) {
        let line = [UInt8](lineSlice)
        if line.isEmpty { continue }
        if line.starts(with: Array("tar: ".utf8)) || line.starts(with: Array("bsdtar: ".utf8)) { continue }

        var tokens: [[UInt8]] = []
        var cur: [UInt8] = []
        for b in line {
            if b == 0x20 || b == 0x09 {
                if !cur.isEmpty { tokens.append(cur); cur = [] }
            } else {
                cur.append(b)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        guard tokens.count >= 9 else { continue }
        guard let sizeStr = String(bytes: tokens[4], encoding: .ascii), let size = Int64(sizeStr) else { continue }

        let perms = tokens[0]
        var nameBytes = [UInt8]()
        for (idx, tk) in tokens.enumerated() where idx >= 8 {
            if idx > 8 { nameBytes.append(0x20) }
            nameBytes.append(contentsOf: tk)
        }
        let isDir = perms.first == 0x64 || nameBytes.last == 0x2F
        if nameBytes.last == 0x2F { nameBytes.removeLast() }
        if nameBytes.isEmpty { continue }

        let month = String(bytes: tokens[5], encoding: .ascii) ?? ""
        let day = String(bytes: tokens[6], encoding: .ascii) ?? ""
        let timeOrYear = String(bytes: tokens[7], encoding: .ascii) ?? ""

        entries.append(RawEntry(nameBytes: Data(nameBytes), size: size,
                                date: normalizeTarDate(month, day, timeOrYear),
                                isDir: isDir, utf8Flag: false))
        if entries.count >= entryLimit { break }
    }
    if entries.isEmpty { throw ReadError.badFormat("无法读取该归档，可能已加密或格式不支持") }
    return entries
}

// MARK: - 目录树

final class Node: NSObject {
    let name: String
    let path: String
    var isDir: Bool
    var size: Int64 = 0
    var date: String = ""
    var children: [Node] = []

    init(name: String, path: String, isDir: Bool) {
        self.name = name
        self.path = path
        self.isDir = isDir
        super.init()
    }

    @discardableResult
    func aggregate() -> Int64 {
        if !isDir { return size }
        var total: Int64 = 0
        for c in children { total += c.aggregate() }
        size = total
        return total
    }

    func sortDeep() {
        children.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for c in children { c.sortDeep() }
    }

    var fileCount: Int {
        isDir ? children.reduce(0) { $0 + $1.fileCount } : 1
    }
}

func buildTree(_ items: [(String, RawEntry)]) -> Node {
    let root = Node(name: "", path: "", isDir: true)
    var index: [String: Node] = ["": root]

    func ensureDir(_ path: String) -> Node {
        if let existing = index[path] {
            existing.isDir = true
            return existing
        }
        let parentPath = (path as NSString).deletingLastPathComponent
        let parent = (parentPath.isEmpty || parentPath == "." || parentPath == "/") ? root : ensureDir(parentPath)
        let node = Node(name: (path as NSString).lastPathComponent, path: path, isDir: true)
        parent.children.append(node)
        index[path] = node
        return node
    }

    for (rawPath, entry) in items {
        var p = rawPath
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        if p.hasSuffix("/") { p = String(p.dropLast()) }
        guard !p.isEmpty else { continue }

        if entry.isDir {
            let node = ensureDir(p)
            if node.date.isEmpty { node.date = entry.date }
        } else {
            let parentPath = (p as NSString).deletingLastPathComponent
            let parent = (parentPath.isEmpty || parentPath == ".") ? root : ensureDir(parentPath)
            let node = Node(name: (p as NSString).lastPathComponent, path: p, isDir: false)
            node.size = entry.size
            node.date = entry.date
            parent.children.append(node)
            index[p] = node
        }
    }
    root.sortDeep()
    root.aggregate()
    return root
}

// MARK: - 解压

/// 目标卷是否支持扩展属性（APFS / HFS+ 支持，ExFAT / FAT32 / 网络盘不支持）
func volumeSupportsXattr(_ path: String) -> Bool {
    var s = statfs()
    guard statfs(path, &s) == 0 else { return true }
    let t = withUnsafeBytes(of: &s.f_fstypename) { buf -> String in
        String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return t == "apfs" || t == "hfs"
}

/// 清理解压产生的 macOS 元数据垃圾：
/// `__MACOSX` 目录、`.DS_Store`，以及（仅非 APFS 卷）`._xxx` 影子文件。
///
/// 注意：`._xxx` 被系统当作 AppleDouble 处理，**Foundation 的目录枚举会直接
/// 跳过它们**（`FileManager.enumerator` / `contentsOfDirectory` 都看不到，
/// 但 `ls` 和 `find` 能看到），所以必须借助 find，不能在 Swift 里自己遍历。
///
/// 另外 tar 的 `--exclude "__MACOSX/*"` 只能排除一层，深层目录照样会被建出来，
/// 所以这里不做前置排除，统一在解压后清理。
func cleanupJunk(_ dest: String, removeAppleDouble: Bool) {
    var args = [dest, "-depth", "(", "-name", "__MACOSX", "-o", "-name", ".DS_Store"]
    if removeAppleDouble { args += ["-o", "-name", "._*"] }
    // 用 rm -rf 而不是 -delete：-delete 只删空目录，而 __MACOSX 里装着 ._xxx 文件，
    // 目录非空就删不掉。
    args += [")", "-exec", "/bin/rm", "-rf", "{}", "+"]
    _ = runCommand("/usr/bin/find", args)
}

// MARK: - 通配符转义

/// 给名字里的 shell 通配符加反斜杠转义。
/// libarchive 把传给它的名字当 pattern 解释，「报告[2024].txt」会被理解成
/// 「报告 后面跟 2/0/2/4 中任意一个字符」，于是匹配不到任何条目、解压直接失败。
/// bsdtar 3.5 没有 --no-wildcards 开关，只能靠转义。
func escapeGlob(_ s: String) -> String {
    var out = ""
    for ch in s {
        if "*?[]\\".contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

/// 某个成员路径的所有上级目录（从最近一级往上）。
/// 解压前只预建这些就够了 —— 把包里全部目录都建出来会凭空多出一堆空文件夹。
func parentChain(of path: String) -> [String] {
    var out: [String] = []
    var p = (path as NSString).deletingLastPathComponent
    while !p.isEmpty, p != ".", p != "/", !out.contains(p) {
        out.append(p)
        p = (p as NSString).deletingLastPathComponent
    }
    return out
}

func performExtract(_ path: String, kind: ArchiveKind, names: [String]?, to dest: String,
                    encoding: NameEncoding, dirs: [String]) -> (ok: Bool, msg: String) {
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
    } catch {
        return (false, "无法创建目标文件夹：\n\(error.localizedDescription)")
    }

    // 先把所有目录建出来。
    // 有些包的目录条目没带尾部斜杠、或没标目录属性，解压器会把它当普通文件创建，
    // 之后写子文件就报 "Not a directory"。预先建好可以绕开这类不规范包。
    for d in dirs {
        let full = (dest as NSString).appendingPathComponent(d)
        try? fm.createDirectory(atPath: full, withIntermediateDirectories: true)
    }

    // 参数太多会撞 ARG_MAX，超过就分批
    var groups: [[String]] = []
    if let names {
        if names.count > 800 {
            var i = 0
            while i < names.count {
                groups.append(Array(names[i..<min(i + 800, names.count)]))
                i += 800
            }
        } else if !names.isEmpty {
            groups.append(names)
        }
    }
    if groups.isEmpty { groups.append([]) }   // 空数组 = 解压全部

    var failures: [String] = []
    for group in groups {
        var args: [String] = []

        // 关键修复：ZIP 解压不再用 unzip。
        // /usr/bin/unzip 按 CP437 解释没有 UTF-8 标志位的文件名，GBK 中文名会被解成
        // 一堆问号和非法字节，随后 mkdir 直接 EINVAL（就是「checkdir error: Invalid argument」）。
        // 改用系统自带的 libarchive（bsdtar），显式告诉它头部字符集，
        // 与列表显示用的编码保持一致，解出来的名字才不会跟预览对不上。
        if kind == .zip, let cs = encoding.archiveCharset {
            args += ["--options", "hdrcharset=\(cs)"]
        }

        // 跳过 macOS 打包时塞进来的元数据（--exclude 只能挡一层，后面还会统一清一次）
        args += ["--exclude", "__MACOSX", "--exclude", ".DS_Store"]

        args += ["-xf", path, "-C", dest]
        if !group.isEmpty { args += group }

        let r = runCommand("/usr/bin/tar", args)
        guard r.code != 0 else { continue }
        let text = String(data: r.data, encoding: .utf8) ?? ""
        // bsdtar 对「模式没匹配到任何条目」也返回非 0，这不是解压失败
        let significant = text.split(separator: "\n").filter { line in
            let l = line.lowercased()
            if l.contains("not found in archive") { return false }
            if l.contains("excluded filename not matched") { return false }
            if l.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            return true
        }
        if !significant.isEmpty {
            failures += significant.map(String.init)
            break
        }
    }

    if !failures.isEmpty {
        return (false, "解压失败。\n\n\(failures.joined(separator: "\n").suffix(700))")
    }

    // 清理解压产生的元数据垃圾（__MACOSX、.DS_Store，非 APFS 卷还有 ._xxx）
    cleanupJunk(dest, removeAppleDouble: !volumeSupportsXattr(dest))

    return (true, dest)
}

// MARK: - 双击打开：缓存

/// 预览缓存根目录。双击文件时解压到这里，再用系统默认程序打开。
func previewCacheRoot() -> String {
    let base = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
        ?? NSTemporaryDirectory()
    return (base as NSString).appendingPathComponent("com.local.archivepreview/preview")
}

/// FNV-1a 哈希。不能用 String.hashValue —— Swift 每次启动会换随机种子，跨进程不稳定，
/// 那样每次开同一个包都会生成新缓存目录。
func stableHash(_ s: String) -> String {
    var h: UInt32 = 2166136261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return String(h, radix: 16)
}

/// 启动时清掉一天前的缓存。
/// 保留当次的：用户双击打开的文件可能还开在别的编辑器里，立刻删会让对方报「文件已删除」。
func purgeStalePreviewCache() {
    let fm = FileManager.default
    let root = previewCacheRoot()
    guard let items = try? fm.contentsOfDirectory(atPath: root) else { return }
    let cutoff = Date().addingTimeInterval(-24 * 3600)
    for name in items {
        let p = (root as NSString).appendingPathComponent(name)
        guard let attrs = try? fm.attributesOfItem(atPath: p),
              let m = attrs[.modificationDate] as? Date else { continue }
        if m < cutoff { try? fm.removeItem(atPath: p) }
    }
}


// MARK: - 界面辅助

func makeLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
               color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
    let tf = NSTextField(labelWithString: text)
    tf.translatesAutoresizingMaskIntoConstraints = false
    tf.font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                   : NSFont.systemFont(ofSize: size, weight: weight)
    tf.textColor = color
    tf.lineBreakMode = .byTruncatingTail
    tf.cell?.wraps = false
    tf.isSelectable = false
    return tf
}

func makeButton(_ title: String, prominent: Bool = false) -> NSButton {
    let b = NSButton(title: title, target: nil, action: nil)
    b.translatesAutoresizingMaskIntoConstraints = false
    b.bezelStyle = prominent ? .rounded : .texturedRounded
    b.setButtonType(.momentaryPushIn)
    if prominent { b.font = NSFont.systemFont(ofSize: 13, weight: .medium) }
    return b
}

// MARK: - 自绘单元格（绕开 NSTextField 在深色模式表格里的绘制问题）

final class RowCellView: NSTableCellView {
    var text: String = "" { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var tint: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }
    var textColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    var font: NSFont = NSFont.systemFont(ofSize: 13) { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// 所在行是否被选中。选中时不能自绘底色，否则会把整行的选中高亮盖掉。
    private var rowSelected: Bool { (superview as? NSTableRowView)?.isSelected ?? false }
    /// 选中高亮是否为「强调」样式（窗口是活动窗口时才是蓝色）。
    /// 非强调时是灰色条，白字会看不清，所以要退回普通文字色。
    private var rowEmphasized: Bool { (superview as? NSTableRowView)?.isEmphasized ?? false }

    override func draw(_ dirtyRect: NSRect) {
        // 注意：这里坚决不要填充背景。
        // 行背景（含选中高亮）由 NSTableRowView 负责，单元格再刷一层不透明色
        // 就会把高亮切成一段一段的。
        let useSelectionColor = rowSelected && rowEmphasized
        let fg = useSelectionColor ? NSColor.selectedTextColor : textColor
        var x: CGFloat = 2
        if let img = icon {
            let side: CGFloat = 14
            let y = (bounds.height - side) / 2
            let tinted = tintedImage(img, color: useSelectionColor ? .selectedTextColor : tint)
            tinted.draw(in: NSRect(x: x, y: y, width: side, height: side),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
            x += side + 6
        }
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg
        ]
        let available = bounds.width - x - 4
        guard available > 4 else { return }
        let size = (text as NSString).size(withAttributes: attrs)
        let h = min(size.height, bounds.height)
        var originX = x
        if alignment == .right { originX = max(x, bounds.width - size.width - 6) }
        // 宽度必须从这里算起，否则右对齐时 rect 会溢出 bounds 被裁掉（"6 bytes" 变 "6 by"）
        let rectW = max(4, bounds.width - originX - (alignment == .right ? 6 : 4))
        let rect = NSRect(x: originX, y: (bounds.height - h) / 2, width: rectW, height: h)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = alignment
        var a = attrs
        a[.paragraphStyle] = para
        (text as NSString).draw(in: rect, withAttributes: a)
    }

    private func tintedImage(_ img: NSImage, color: NSColor) -> NSImage {
        let out = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }
}

// MARK: - 主界面（树形）

class PreviewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    let archivePath: String
    let kind: ArchiveKind
    let rawEntries: [RawEntry]
    /// 「自动识别」实际落到哪个编码上。列表显示和解压都统一用它，
    /// 否则会出现列表正常、解压出来的文件名全是问号。
    let detectedEncoding: NameEncoding

    var tree: Node = Node(name: "", path: "", isDir: true)
    var encoding: NameEncoding = .auto
    var expandedPaths = Set<String>()
    var firstLoad = true

    /// 当前真正生效的编码（auto 时取检测结果）
    var effectiveEncoding: NameEncoding { encoding == .auto ? detectedEncoding : encoding }

    let outline = NSOutlineView()
    let searchField = NSSearchField()
    let encodingPopup = NSPopUpButton()
    let selectedLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    let countNote = makeLabel("", size: 11, color: .secondaryLabelColor)
    let hintLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    let statsLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    let spinner = NSProgressIndicator()
    let spinnerLabel = makeLabel("正在解压…", size: 12, color: .secondaryLabelColor)
    var busyBox: NSView?

    init(path: String, kind: ArchiveKind, entries: [RawEntry]) {
        self.archivePath = path
        self.kind = kind
        self.rawEntries = entries
        self.detectedEncoding = detectEncoding(entries)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        buildUI()
        encodingPopup.selectItem(withTag: encoding.rawValue)
        rebuildTree()

        // 窗口变成/失去活动状态时，选中高亮会在蓝色和灰色之间切换，
        // 文字颜色跟着变，所以要主动让可见单元格重绘。
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            nc.addObserver(self, selector: #selector(refreshVisibleRows), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func refreshVisibleRows() {
        outline.enumerateAvailableRowViews { rowView, _ in
            for sub in rowView.subviews { sub.needsDisplay = true }
        }
    }

    // MARK: 界面

    func buildUI() {
        let v = view

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSWorkspace.shared.icon(forFile: archivePath)
        icon.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(icon)

        let nameLabel = makeLabel((archivePath as NSString).lastPathComponent, size: 15, weight: .semibold)
        let pathLabel = makeLabel(archivePath, size: 10, color: .tertiaryLabelColor)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        statsLabel.font = NSFont.systemFont(ofSize: 11)
        statsLabel.textColor = .secondaryLabelColor

        for s in [nameLabel, pathLabel, statsLabel] { v.addSubview(s) }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            nameLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 13),

            statsLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            statsLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            pathLabel.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 2),
        ])

        let sep1 = NSBox()
        sep1.translatesAutoresizingMaskIntoConstraints = false
        sep1.boxType = .separator
        v.addSubview(sep1)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "筛选路径或文件名…"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        v.addSubview(searchField)

        let encLabel = makeLabel("字符集", size: 11, color: .secondaryLabelColor)
        v.addSubview(encLabel)

        encodingPopup.translatesAutoresizingMaskIntoConstraints = false
        for e in NameEncoding.allCases {
            encodingPopup.addItem(withTitle: e.title)
            encodingPopup.lastItem?.tag = e.rawValue
        }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged(_:))
        encodingPopup.controlSize = .small
        encodingPopup.font = NSFont.systemFont(ofSize: 11)
        v.addSubview(encodingPopup)

        v.addSubview(selectedLabel)

        let expandBtn = makeButton("展开全部")
        expandBtn.target = self
        expandBtn.action = #selector(expandAll(_:))
        expandBtn.controlSize = .small
        expandBtn.font = NSFont.systemFont(ofSize: 11)
        v.addSubview(expandBtn)

        let collapseBtn = makeButton("折叠")
        collapseBtn.target = self
        collapseBtn.action = #selector(collapseAll(_:))
        collapseBtn.controlSize = .small
        collapseBtn.font = NSFont.systemFont(ofSize: 11)
        v.addSubview(collapseBtn)

        NSLayoutConstraint.activate([
            sep1.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sep1.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 12),

            searchField.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            searchField.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 10),
            searchField.widthAnchor.constraint(equalToConstant: 200),

            encLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 12),
            encLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            encodingPopup.leadingAnchor.constraint(equalTo: encLabel.trailingAnchor, constant: 5),
            encodingPopup.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            encodingPopup.widthAnchor.constraint(equalToConstant: 156),

            selectedLabel.trailingAnchor.constraint(equalTo: expandBtn.leadingAnchor, constant: -10),
            selectedLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            expandBtn.trailingAnchor.constraint(equalTo: collapseBtn.leadingAnchor, constant: -6),
            expandBtn.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            collapseBtn.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            collapseBtn.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
        ])

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        colName.title = "名称"
        colName.minWidth = 220
        colName.width = 440
        let colSize = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        colSize.title = "大小"
        colSize.width = 88
        let colDate = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        colDate.title = "修改时间"
        colDate.width = 132
        for c in [colName, colSize, colDate] { outline.addTableColumn(c) }
        outline.outlineTableColumn = colName
        outline.headerView = NSTableHeaderView()
        outline.allowsMultipleSelection = true
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.usesAlternatingRowBackgroundColors = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.style = .automatic
        // 双击：文件 → 解压到缓存并用系统默认程序打开；文件夹 → 展开/折叠
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked(_:))

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        v.addSubview(scroll)

        v.addSubview(countNote)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: countNote.topAnchor, constant: -4),

            countNote.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            countNote.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -14),
            countNote.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -46),
        ])

        let sep2 = NSBox()
        sep2.translatesAutoresizingMaskIntoConstraints = false
        sep2.boxType = .separator
        v.addSubview(sep2)

        let cancel = makeButton("关闭")
        cancel.target = self
        cancel.action = #selector(cancelTapped(_:))
        cancel.keyEquivalent = "."

        let choose = makeButton("解压到…")
        choose.target = self
        choose.action = #selector(chooseFolderTapped(_:))

        let sibling = makeButton("解压到同名文件夹")
        sibling.target = self
        sibling.action = #selector(siblingFolderTapped(_:))

        let here = makeButton("解压到此处", prominent: true)
        here.target = self
        here.action = #selector(hereTapped(_:))
        here.keyEquivalent = "\r"

        let bstack = NSStackView(views: [cancel, choose, sibling, here])
        bstack.translatesAutoresizingMaskIntoConstraints = false
        bstack.orientation = .horizontal
        bstack.spacing = 8
        bstack.alignment = .centerY
        v.addSubview(bstack)

        v.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            sep2.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sep2.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -44),

            bstack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            bstack.centerYAnchor.constraint(equalTo: v.bottomAnchor, constant: -22),

            hintLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            hintLabel.trailingAnchor.constraint(equalTo: bstack.leadingAnchor, constant: -10),
            hintLabel.centerYAnchor.constraint(equalTo: v.bottomAnchor, constant: -22),
        ])

        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        box.layer?.cornerRadius = 12
        v.addSubview(box)
        box.addSubview(spinner)
        box.addSubview(spinnerLabel)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 230),
            box.heightAnchor.constraint(equalToConstant: 78),
            spinner.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            spinnerLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            spinnerLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
        ])
        box.isHidden = true
        busyBox = box
    }

    // MARK: 构建树

    func rebuildTree() {
        if !firstLoad {
            expandedPaths.removeAll()
            func walk(_ n: Node) {
                for c in n.children where c.isDir {
                    if outline.isItemExpanded(c) { expandedPaths.insert(c.path) }
                    walk(c)
                }
            }
            walk(tree)
        }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let enc = effectiveEncoding
        var items: [(String, RawEntry)] = []
        items.reserveCapacity(rawEntries.count)
        for e in rawEntries {
            let name = decodeName(e.nameBytes, enc, utf8Flagged: e.utf8Flag)
            if !query.isEmpty && !name.localizedCaseInsensitiveContains(query) { continue }
            items.append((name, e))
        }

        tree = buildTree(items)
        outline.reloadData()

        if firstLoad {
            // 默认全部折叠，一个都不展开
            firstLoad = false
        } else if !query.isEmpty {
            // 筛选时全部展开，否则匹配项都藏在折叠的文件夹里看不见
            outline.expandItem(nil, expandChildren: true)
        } else {
            func restore(_ n: Node) {
                for c in n.children where c.isDir {
                    if expandedPaths.contains(c.path) { outline.expandItem(c) }
                    restore(c)
                }
            }
            restore(tree)
        }

        updateStats()
        updateLabels()
    }

    func updateStats() {
        let files = rawEntries.filter { !$0.isDir }
        var dirCount = 0
        func countDirs(_ n: Node) {
            for c in n.children where c.isDir { dirCount += 1; countDirs(c) }
        }
        countDirs(tree)
        let total = rawEntries.reduce(Int64(0)) { $0 + $1.size }

        var parts = ["\(files.count) 个文件", "\(dirCount) 个文件夹", "解压后约 \(sizeString(total))"]
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { parts.append("已筛选") }
        statsLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    func updateLabels() {
        let rows = outline.selectedRowIndexes
        var fileCount = 0
        var bytes: Int64 = 0
        for r in rows {
            guard let n = outline.item(atRow: r) as? Node else { continue }
            fileCount += n.fileCount
            bytes += n.size
        }
        if rows.isEmpty {
            hintLabel.stringValue = "未选中 → 解压全部内容（双击列表里的文件可直接打开）"
            selectedLabel.stringValue = ""
        } else {
            hintLabel.stringValue = "已选 \(fileCount) 个文件 · \(sizeString(bytes))"
            selectedLabel.stringValue = "已选 \(rows.count) 项"
        }
        countNote.stringValue = rawEntries.count >= entryLimit ? "条目超过 \(entryLimit) 个，已截断显示" : ""
    }

    // MARK: 数据源

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let n = item as? Node { return n.children.count }
        return tree.children.count
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let n = item as? Node { return n.children[index] }
        return tree.children[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let n = item as? Node { return n.isDir && !n.children.isEmpty }
        return false
    }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let col = col else { return nil }
        let key = col.identifier.rawValue
        let cellId = NSUserInterfaceItemIdentifier("cell-" + key)

        var cell = ov.makeView(withIdentifier: cellId, owner: self) as? RowCellView
        if cell == nil {
            cell = RowCellView()
            cell!.identifier = cellId
            if key == "name" {
                cell!.font = NSFont.systemFont(ofSize: 13)
                cell!.textColor = .labelColor
            } else {
                cell!.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                cell!.textColor = .secondaryLabelColor
                cell!.alignment = .right
            }
        }
        guard let view = cell else { return nil }

        switch key {
        case "name":
            view.text = node.name
            view.icon = symbolImage(for: node)
            view.tint = node.isDir ? .controlAccentColor : .tertiaryLabelColor
        case "size":
            view.text = (node.isDir && node.size == 0) ? "—" : sizeString(node.size)
            view.icon = nil
        default:
            view.text = node.date
            view.icon = nil
        }
        return view
    }

    func symbolImage(for node: Node) -> NSImage? {
        let name = node.isDir ? "folder.fill" : fileSymbol(for: node.name)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
    }

    func fileSymbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log", "json", "xml", "yml", "yaml", "ini", "csv": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "svg": return "photo"
        case "mp4", "mov", "avi", "mkv", "webm": return "film"
        case "mp3", "wav", "flac", "aac", "m4a": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "gz", "tar": return "doc.zipper"
        case "app", "exe", "dmg": return "shippingbox"
        case "swift", "py", "js", "ts", "c", "cpp", "h", "java", "sh", "kt": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // 文字颜色跟着选中状态走，行视图不会自动让子视图重绘，这里手动触发
        refreshVisibleRows()
        updateLabels()
    }

    // MARK: 动作

    @objc func searchChanged(_ sender: Any) { rebuildTree() }

    @objc func encodingChanged(_ sender: Any) {
        encoding = NameEncoding(rawValue: encodingPopup.selectedTag()) ?? .auto
        expandedPaths.removeAll()
        rebuildTree()
    }

    @objc func expandAll(_ sender: Any) {
        outline.expandItem(nil, expandChildren: true)
    }

    @objc func collapseAll(_ sender: Any) {
        outline.collapseItem(nil, collapseChildren: true)
    }

    @objc func cancelTapped(_ sender: Any) { NSApp.terminate(nil) }

    // MARK: 双击打开

    @objc func rowDoubleClicked(_ sender: Any) {
        var row = outline.clickedRow
        if row < 0 { row = outline.selectedRow }
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        if node.isDir {
            // 自己接管了 doubleAction，NSOutlineView 默认的双击展开就不生效了，这里补上
            if outline.isItemExpanded(node) { outline.collapseItem(node) }
            else { outline.expandItem(node) }
            return
        }
        openMember(node)
    }

    /// 按行号打开（调试用，逻辑与双击一致）
    func openRow(_ row: Int) {
        guard row >= 0, row < outline.numberOfRows,
              let node = outline.item(atRow: row) as? Node, !node.isDir else { return }
        openMember(node)
    }

    /// 本次会话的缓存目录。按「压缩包路径 + 大小 + 修改时间」区分，
    /// 包一改动就换目录，不会把旧内容当成新内容打开。
    var memberCacheDir: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: archivePath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return (previewCacheRoot() as NSString)
            .appendingPathComponent(stableHash("\(archivePath)|\(size)|\(mtime)"))
    }

    func openMember(_ node: Node) {
        let dest = memberCacheDir
        let target = (dest as NSString).appendingPathComponent(node.path)
        // 已经解过一次就直接复用，免得同一个文件双击两次解两次
        if FileManager.default.fileExists(atPath: target) {
            launch(URL(fileURLWithPath: target))
            return
        }

        let enc = effectiveEncoding
        let arc = archivePath
        let kind = self.kind
        // 先把父目录建好：有些包的目录条目缺失，解压器写子文件时会报 Not a directory
        let dirs = parentChain(of: node.path)

        busyBox?.isHidden = false
        spinner.startAnimation(nil)
        spinnerLabel.stringValue = "正在打开…"

        DispatchQueue.global(qos: .userInitiated).async {
            let r = performExtract(arc, kind: kind, names: [escapeGlob(node.path)],
                                   to: dest, encoding: enc, dirs: dirs)
            var found = target
            if !FileManager.default.fileExists(atPath: found) {
                // 兜底：包内路径和实际落盘路径对不上时，按文件名找一遍
                found = Self.findMember(node.name, under: dest) ?? ""
            }
            DispatchQueue.main.async {
                self.spinner.stopAnimation(nil)
                self.busyBox?.isHidden = true
                if found.isEmpty {
                    self.showOpenFailure(node, detail: r.msg)
                } else {
                    self.launch(URL(fileURLWithPath: found))
                }
            }
        }
    }

    static func findMember(_ name: String, under dir: String) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return nil }
        for case let rel as String in en {
            guard (rel as NSString).lastPathComponent == name else { continue }
            let full = (dir as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { return full }
        }
        return nil
    }

    /// 会被系统当成「程序」直接执行的类型。压缩包来源不明时不能替用户按下运行键，
    /// 解压后只在访达里选中，由用户自己决定。
    static let runnableExtensions: Set<String> = [
        "app", "pkg", "mpkg", "command", "workflow", "scpt", "scptd", "terminal", "action"
    ]

    func launch(_ url: URL) {
        // 调试开关：只打印路径不真的启动，便于命令行验证
        if ProcessInfo.processInfo.environment["AP_NO_LAUNCH"] == "1" {
            print(url.path)
            NSApp.terminate(nil)
            return
        }
        let ws = NSWorkspace.shared
        if Self.runnableExtensions.contains(url.pathExtension.lowercased()) {
            ws.activateFileViewerSelecting([url])
            let a = NSAlert()
            a.alertStyle = .informational
            a.messageText = "「\(url.lastPathComponent)」是可执行程序"
            a.informativeText = "出于安全考虑，压缩包里的程序不会被直接运行。\n已经解压并在访达中选中，确认来源可靠后再双击打开。"
            a.addButton(withTitle: "好")
            a.runModal()
            return
        }
        if ws.urlForApplication(toOpen: url) != nil {
            ws.open(url)
        } else {
            // 系统里没有能打开这种类型的程序，退一步在访达里选中它
            ws.activateFileViewerSelecting([url])
        }
    }

    func showOpenFailure(_ node: Node, detail: String) {
        if ProcessInfo.processInfo.environment["AP_NO_LAUNCH"] == "1" {
            let msg = "打开失败: \(node.path)\n\(detail)\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "无法打开「\(node.name)」"
        a.informativeText = detail.isEmpty ? "解压这个文件时出错了。" : detail
        a.addButton(withTitle: "好")
        a.runModal()
    }

    // MARK: 解压

    /// 选中项 → libarchive 的匹配 pattern（已转义）。
    /// 目录用「dir/」形式 —— libarchive 认这个前缀，会递归解出整个子树，
    /// 比自己展开成几千个成员名简洁得多。
    /// 同时返回需要预建的父目录链。
    func selectedExtraction() -> (patterns: [String], parents: [String])? {
        let rows = outline.selectedRowIndexes
        if rows.isEmpty { return nil }
        var patterns: [String] = []
        var parents: [String] = []
        var seen = Set<String>()
        for r in rows {
            guard let n = outline.item(atRow: r) as? Node, !n.path.isEmpty else { continue }
            let pattern = n.isDir ? escapeGlob(n.path) + "/" : escapeGlob(n.path)
            if seen.insert(pattern).inserted { patterns.append(pattern) }
            for p in parentChain(of: n.path) where !parents.contains(p) { parents.append(p) }
        }
        return patterns.isEmpty ? nil : (patterns, parents)
    }

    @objc func hereTapped(_ sender: Any) {
        let parent = (archivePath as NSString).deletingLastPathComponent
        let folderName = (parent as NSString).lastPathComponent
        let count = outline.selectedRowIndexes.isEmpty
            ? rawEntries.filter { !$0.isDir }.count
            : outline.selectedRowIndexes.count
        guard confirm("把选中的 \(count) 项解压到「\(folderName)」？\n\n注意：不会自动新建子文件夹，解压出来的内容会直接散落在该目录里。") else { return }
        extract(to: parent)
    }

    @objc func siblingFolderTapped(_ sender: Any) {
        let parent = (archivePath as NSString).deletingLastPathComponent
        let base = ((archivePath as NSString).lastPathComponent as NSString).deletingPathExtension
        extract(to: uniqueFolder("\(parent)/\(base)"))
    }

    @objc func chooseFolderTapped(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到这里"
        panel.message = "选择一个目标文件夹"
        if panel.runModal() == .OK, let url = panel.url { extract(to: url.path) }
    }

    func confirm(_ msg: String) -> Bool {
        let a = NSAlert()
        a.messageText = "确认解压"
        a.informativeText = msg
        a.addButton(withTitle: "解压")
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }

    func extract(to dest: String) {
        let sel = selectedExtraction()
        let enc = effectiveEncoding
        // 全量解压时把所有目录都预建出来（兼容目录条目缺失的不规范包）；
        // 只解压选中项时，多建别的目录只会凭空多出空文件夹。
        let dirs: [String]
        if let sel {
            dirs = sel.parents
        } else {
            dirs = rawEntries.filter { $0.isDir }
                              .map { decodeName($0.nameBytes, enc, utf8Flagged: $0.utf8Flag) }
                              .filter { !$0.isEmpty }
        }
        busyBox?.isHidden = false
        spinner.startAnimation(nil)
        spinnerLabel.stringValue = "正在解压…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = performExtract(self.archivePath, kind: self.kind, names: sel?.patterns,
                                   to: dest, encoding: enc, dirs: dirs)
            DispatchQueue.main.async {
                self.spinner.stopAnimation(nil)
                self.busyBox?.isHidden = true
                self.finish(ok: r.ok, msg: r.msg)
            }
        }
    }

    func finish(ok: Bool, msg: String) {
        let a = NSAlert()
        a.alertStyle = ok ? .informational : .critical
        a.messageText = ok ? "解压完成" : "解压失败"
        a.informativeText = ok ? "已解压到：\n\(msg)" : msg
        if ok {
            a.addButton(withTitle: "在访达中显示")
            a.addButton(withTitle: "关闭")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: msg)])
            }
        } else {
            a.addButton(withTitle: "改用系统自带解压")
            a.addButton(withTitle: "关闭")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open([URL(fileURLWithPath: archivePath)],
                                        withAppBundleIdentifier: "com.apple.archiveutility",
                                        options: [],
                                        additionalEventParamDescriptor: nil,
                                        launchIdentifiers: nil)
            }
        }
        NSApp.terminate(nil)
    }
}

// MARK: - 不支持格式

class UnsupportedController: NSViewController {
    let archivePath: String
    let note: String

    init(path: String, note: String) {
        self.archivePath = path
        self.note = note
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSWorkspace.shared.icon(forFile: archivePath)
        view.addSubview(icon)

        let title = makeLabel("无法预览内容", size: 15, weight: .semibold)
        let box = NSTextField(wrappingLabelWithString: note)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.alignment = .center
        box.font = NSFont.systemFont(ofSize: 12)
        box.textColor = .secondaryLabelColor
        let file = makeLabel((archivePath as NSString).lastPathComponent, size: 11, color: .tertiaryLabelColor)
        view.addSubview(title)
        view.addSubview(box)
        view.addSubview(file)

        let bypass = makeButton("改用系统自带解压", prominent: true)
        bypass.target = self
        bypass.action = #selector(bypassTapped(_:))
        let cancel = makeButton("关闭")
        cancel.target = self
        cancel.action = #selector(cancelTapped(_:))
        let stack = NSStackView(views: [cancel, bypass])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            box.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            box.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            file.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 14),
            file.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    @objc func bypassTapped(_ sender: Any) {
        NSWorkspace.shared.open([URL(fileURLWithPath: archivePath)],
                                withAppBundleIdentifier: "com.apple.archiveutility",
                                options: [],
                                additionalEventParamDescriptor: nil,
                                launchIdentifiers: nil)
        NSApp.terminate(nil)
    }

    @objc func cancelTapped(_ sender: Any) { NSApp.terminate(nil) }
}

// MARK: - 识型

enum ListResult {
    case ok(kind: ArchiveKind, entries: [RawEntry])
    case unsupported(String)
}

func detectAndList(_ path: String) -> ListResult {
    let lower = path.lowercased()
    let zipLike = [".zip", ".ipa", ".jar", ".whl", ".apk", ".zipx", ".xpi", ".crx"]
    // 这些交给系统的 libarchive（bsdtar 3.7 内置 7z / rar 读取）
    let libarchiveLike = [".tar", ".tgz", ".gz", ".bz2", ".xz", ".cpio",
                          ".rar", ".7z", ".cbr", ".cb7"]
    do {
        if zipLike.contains(where: { lower.hasSuffix($0) }) {
            return .ok(kind: .zip, entries: try readZipEntries(path))
        }
        if libarchiveLike.contains(where: { lower.hasSuffix($0) }) {
            return .ok(kind: .tar, entries: try readTarEntries(path))
        }
    } catch {
        return .unsupported("无法读取这个压缩包。\n\(error.localizedDescription)")
    }
    // 扩展名不认识，再按内容猜一次（libarchive 能自动识别格式）
    if let byContent = try? readTarEntries(path), !byContent.isEmpty {
        return .ok(kind: .tar, entries: byContent)
    }
    return .unsupported("尚未支持的格式：.\((path as NSString).pathExtension)")
}

// MARK: - 应用生命周期

class AppDelegate: NSObject, NSApplicationDelegate {

    /// 必须强持有：窗口只强引用 vc.view，控制器本身若没人持有会被释放，
    /// outline 的 dataSource / delegate 随之变 nil，表格行会整体消失。
    var controller: NSViewController?
    var openedOnce = false
    var delivered = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 顺手回收一天前的预览缓存（双击打开的文件解压到这里）
        purgeStalePreviewCache()
        let listOnly = CommandLine.arguments.dropFirst().contains("--list")
        let encArg = CommandLine.arguments.dropFirst().first { $0.hasPrefix("--enc=") }?
            .replacingOccurrences(of: "--enc=", with: "")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !self.openedOnce else { return }
            let path = self.delivered ? "" : (CommandLine.arguments.dropFirst().last(where: { !$0.hasPrefix("--") }) ?? "")
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                print("用法: 压缩包预览器 <归档路径> [--list] [--enc=auto|utf8|gbk|big5|sjis|euckr|latin1]")
                NSApp.terminate(nil)
                return
            }
            self.handle(path: path, listOnly: listOnly, encName: encArg)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        delivered = true
        guard !openedOnce else { return true }
        let listOnly = CommandLine.arguments.contains("--list")
        let encArg = CommandLine.arguments.first { $0.hasPrefix("--enc=") }?
            .replacingOccurrences(of: "--enc=", with: "")
        DispatchQueue.main.async { self.handle(path: filename, listOnly: listOnly, encName: encArg) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func encodingFrom(_ name: String?) -> NameEncoding {
        switch (name ?? "").lowercased() {
        case "utf8", "utf-8": return .utf8
        case "gbk", "gb18030", "gb2312": return .gb18030
        case "big5": return .big5
        case "sjis", "shiftjis", "shift-jis": return .shiftJIS
        case "euckr", "euc-kr": return .eucKR
        case "latin1", "latin-1", "cp1252": return .latin1
        default: return .auto
        }
    }

    func handle(path: String, listOnly: Bool, encName: String?) {
        guard !openedOnce else { return }
        openedOnce = true

        let result = detectAndList(path)

        if listOnly {
            switch result {
            case .ok(let kind, let entries):
                let enc = encodingFrom(encName)
                print("kind=\(kind) 条目=\(entries.count) 编码=\(enc.title)")
                var items: [(String, RawEntry)] = []
                for e in entries {
                    items.append((decodeName(e.nameBytes, enc, utf8Flagged: e.utf8Flag), e))
                }
                let tree = buildTree(items)
                func dump(_ n: Node, _ depth: Int) {
                    for c in n.children.prefix(80) {
                        let pad = String(repeating: "  ", count: depth)
                        print("\(pad)\(c.isDir ? "📁" : "  ") \(c.name)  [\(sizeString(c.size))]")
                        if c.isDir { dump(c, depth + 1) }
                    }
                }
                dump(tree, 0)
                exit(0)
            case .unsupported(let msg):
                print("UNSUPPORTED: \(msg)")
                exit(2)
            }
        }

        let vc: NSViewController
        let size: NSSize
        switch result {
        case .ok(let kind, let entries):
            let c = PreviewController(path: path, kind: kind, entries: entries)
            if let e = encName { c.encoding = encodingFrom(e) }
            // 隐藏参数：命令行直接解压，不弹窗口（用于验证解压逻辑 / 脚本调用）
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--extract=") }) {
                let dest = String(arg.dropFirst("--extract=".count))
                let enc = c.effectiveEncoding
                // --extract-item=<相对路径> 可重复，只解压指定项（目录写 dir/ 表示整个子树）
                let rawItems = CommandLine.arguments
                    .filter { $0.hasPrefix("--extract-item=") }
                    .map { String($0.dropFirst("--extract-item=".count)) }
                // 全量解压时预建所有目录；定向解压只建所选项的父目录
                let allDirs = entries.filter { $0.isDir }
                                     .map { decodeName($0.nameBytes, enc, utf8Flagged: $0.utf8Flag) }
                                     .filter { !$0.isEmpty }
                var dirs = allDirs
                if !rawItems.isEmpty {
                    dirs = []
                    for item in rawItems {
                        let bare = item.hasSuffix("/") ? String(item.dropLast()) : item
                        for p in parentChain(of: bare) where !dirs.contains(p) { dirs.append(p) }
                    }
                }
                let r = performExtract(path, kind: kind,
                                       names: rawItems.isEmpty ? nil : rawItems.map(escapeGlob),
                                       to: dest, encoding: enc, dirs: dirs)
                print("编码=\(enc.title)")
                print(r.ok ? "OK: \(r.msg)" : "FAIL: \(r.msg)")
                exit(r.ok ? 0 : 1)
            }
            vc = c
            size = NSSize(width: 820, height: 600)
        case .unsupported(let note):
            vc = UnsupportedController(path: path, note: note)
            size = NSSize(width: 460, height: 260)
        }

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "压缩包预览器"
        // 注意：不要用 contentViewController —— 它会把窗口压成 Auto Layout 的最小拟合尺寸
        let container = vc.view
        container.frame = NSRect(origin: .zero, size: size)
        container.autoresizingMask = [.width, .height]
        win.contentView = container
        win.isReleasedWhenClosed = false
        // 关键：强持有控制器，否则它会被释放，outline 的 dataSource 变 nil，表格行全部消失
        self.controller = vc
        // 用窗口自身背景色，不要给容器开 wantsLayer
        win.backgroundColor = NSColor.windowBackgroundColor
        win.setContentSize(size)
        win.minSize = NSSize(width: 640, height: 300)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 隐藏调试开关：把界面自身渲染成 PNG（不依赖显示器，失败也不影响正常使用）
        if CommandLine.arguments.contains("--expand") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                (vc as? PreviewController)?.outline.expandItem(nil, expandChildren: true)
            }
        }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--select=") }) {
            let row = Int(arg.dropFirst("--select=".count)) ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let pc = vc as? PreviewController, row < pc.outline.numberOfRows {
                    pc.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            }
        }
        // 隐藏调试开关：模拟双击第 N 行（配合 AP_NO_LAUNCH=1 只打印解压出的路径）
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--open=") }) {
            let row = Int(arg.dropFirst("--open=".count)) ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                (vc as? PreviewController)?.openRow(row)
            }
        }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") }) {
            let out = String(arg.dropFirst("--snapshot=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let v = win.contentView {
                    v.wantsLayer = true
                    v.needsDisplay = true
                    v.display()
                    let scale: CGFloat = 2
                    let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
                    if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.scaleBy(x: scale, y: scale)
                        v.layer?.render(in: ctx)
                        if let cg = ctx.makeImage(),
                           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: out))
                        }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
