//  把压缩包的默认打开方式设为 / 改回某个 bundle id
//  用法：
//    SetHandler get [扩展名...]
//    SetHandler set <bundleId> [扩展名...]
//    SetHandler revert [扩展名...]      // 恢复成系统归档实用工具

import Foundation
import CoreServices
import UniformTypeIdentifiers

let defaultExts = ["zip", "tar", "tgz", "gz", "bz2", "xz", "rar", "7z"]
let systemOpener = "com.apple.archiveutility"

let argv = Array(CommandLine.arguments.dropFirst())
let mode = argv.first ?? "get"

var exts: [String] = []
var handlerId: String? = nil
switch mode {
case "get":
    exts = argv.count > 1 ? Array(argv.dropFirst()) : defaultExts
case "revert":
    exts = argv.count > 1 ? Array(argv.dropFirst()) : defaultExts
    handlerId = systemOpener
case "set":
    guard argv.count >= 2 else {
        print("用法: SetHandler set <bundleId> [扩展名...]"); exit(2)
    }
    handlerId = argv[1]
    exts = argv.count > 2 ? Array(argv.dropFirst(2)) : defaultExts
default:
    print("未知模式: \(mode)"); exit(2)
}

func uti(for ext: String) -> String? {
    if let t = UTType(filenameExtension: ext) {
        let id = t.identifier
        // 动态 UTI（如 dyn.xxx）说明系统没登记这个类型，跳过
        if !id.hasPrefix("dyn.") { return id }
    }
    return nil
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

for ext in exts {
    guard let u = uti(for: ext) else {
        print("\(pad(ext, 6)) UTI 未登记，跳过"); continue
    }
    if let hid = handlerId {
        let st = LSSetDefaultRoleHandlerForContentType(u as CFString, .all, hid as CFString)
        let cur = LSCopyDefaultRoleHandlerForContentType(u as CFString, .all)?.takeRetainedValue() as String? ?? "(none)"
        print("\(pad(ext, 6)) \(pad(u, 44)) status=\(st)  当前=\(cur)")
    } else {
        let cur = LSCopyDefaultRoleHandlerForContentType(u as CFString, .all)?.takeRetainedValue() as String? ?? "(none)"
        print("\(pad(ext, 6)) \(pad(u, 44)) \(cur)")
    }
}
