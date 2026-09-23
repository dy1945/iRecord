import Foundation
import AppKit
import ControlProtocol
import Darwin

let usage = """
iRecord CLI

Usage:
  irecord <command> [options]

Commands:
  status                         查看 App、权限和录制状态
  permission                     请求屏幕录制权限
  ls [--search TEXT]             查找可录制窗口
  preview --window-id ID         截取目标窗口 PNG（需 --output）
  start --window-id ID           开始窗口录制
  pause --session-id ID          暂停录制
  resume --session-id ID         继续录制
  stop --session-id ID           停止并导出
  install                        安装 ~/.local/bin/irecord
  uninstall                      移除 CLI，保留 App 和录屏

Preview / stop crop options:
  --crop-points T,R,B,L          按窗口逻辑点裁剪（浏览器推荐）
  --crop-insets T,R,B,L          按原始像素裁剪上、右、下、左

Stop options:
  --output PATH                  指定 MP4、MOV 或 GIF 输出路径
  --max-edge PIXELS              最长边，默认 1920；0 保留原尺寸
  --overwrite                    允许覆盖已有文件

Global options:
  --json                         输出稳定 JSON，供 Agent 使用
  -h, --help                     显示本菜单

Examples:
  irecord ls --search Chrome --json
  irecord preview --window-id 311 --output /tmp/window.png --crop-points 87,0,0,0 --json
  irecord start --window-id 311 --json
  irecord pause --session-id SESSION --json
  irecord resume --session-id SESSION --json
  irecord stop --session-id SESSION --crop-points 87,0,0,0 --json

旧版多级命令仍兼容。App 会自动启动，并沿用 App 的声音、鼠标、帧率和保存目录设置。
"""
let args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
func finish(_ reply: ControlReply, usageError: Bool = false) -> Never {
    if json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(data: try! encoder.encode(reply), encoding: .utf8)!)
    } else if reply.ok {
        if !reply.message.isEmpty { print(reply.message) }
        for (key, value) in reply.values.sorted(by: { $0.key < $1.key }) { print("\(key): \(value)") }
        for window in reply.windows ?? [] { print("\(window["id"] ?? "")\t\(window["app"] ?? "")\t\(window["title"] ?? "")") }
    } else { fputs("\(reply.code): \(reply.message)\n", stderr) }
    exit(reply.ok ? 0 : (usageError ? 2 : 1))
}
if args.isEmpty || args.contains("-h") || args.contains("--help") || args == ["help"] {
    print(usage); exit(0)
}
var words: [String] = []; var options: [String: String] = [:]; var i = 0
while i < args.count {
    let arg = args[i]
    if arg == "--json" || arg == "--overwrite" { options[String(arg.dropFirst(2))] = "true" }
    else if arg.hasPrefix("--") {
        guard ["--search", "--window-id", "--session-id", "--output", "--max-edge", "--crop-insets", "--crop-points"].contains(arg), i + 1 < args.count else {
            finish(ControlReply("invalid_arguments", "Unknown option or missing value: \(arg)"), usageError: true)
        }
        i += 1; options[String(arg.dropFirst(2))] = args[i]
    } else { words.append(arg) }
    i += 1
}
let enteredCommand = words.joined(separator: " ")
let aliases = [
    "permission": "permission request",
    "ls": "windows list",
    "preview": "windows preview",
    "start": "recording start",
    "pause": "recording pause",
    "resume": "recording resume",
    "stop": "recording stop"
]
let command = aliases[enteredCommand] ?? enteredCommand
let allowed: [String: Set<String>] = ["status": [], "permission request": [], "windows list": ["search"],
    "windows preview": ["window-id", "output", "crop-insets", "crop-points"], "recording start": ["window-id"],
    "recording stop": ["session-id", "output", "max-edge", "crop-insets", "crop-points", "overwrite"],
    "recording pause": ["session-id"], "recording resume": ["session-id"], "install": [], "uninstall": []]
guard let keys = allowed[command], Set(options.keys).subtracting(["json"]).isSubset(of: keys) else {
    finish(ControlReply("invalid_arguments", "Invalid command/options. Run irecord -h."), usageError: true)
}
let required: [String: [String]] = ["windows preview": ["window-id", "output"],
    "recording start": ["window-id"], "recording stop": ["session-id"],
    "recording pause": ["session-id"], "recording resume": ["session-id"]]
for key in required[command] ?? [] where options[key] == nil {
    finish(ControlReply("invalid_arguments", "Missing --\(key)."), usageError: true)
}
var executableSize: UInt32 = 0
_NSGetExecutablePath(nil, &executableSize)
var executableBytes = [CChar](repeating: 0, count: Int(executableSize))
_NSGetExecutablePath(&executableBytes, &executableSize)
let executable = URL(fileURLWithPath: String(cString: executableBytes)).resolvingSymlinksInPath()
let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
if command == "install" || command == "uninstall" {
    do {
        let home = fm.homeDirectoryForCurrentUser
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let linkURL = bin.appendingPathComponent("irecord")
        let target = executable.path
        let old = try? fm.destinationOfSymbolicLink(atPath: linkURL.path)
        if fm.fileExists(atPath: linkURL.path) || old != nil {
            guard old == target || (old?.hasSuffix("iRecord.app/Contents/Helpers/irecord") == true) else {
                finish(ControlReply("install_conflict", "Refusing to replace unrelated \(linkURL.path)."))
            }
        }
        let begin = "# >>> iRecord CLI >>>"
        let end = "# <<< iRecord CLI <<<"
        let block = "\(begin)\ncase \":$PATH:\" in *\":$HOME/.local/bin:\"*) ;; *) export PATH=\"$HOME/.local/bin:$PATH\" ;; esac\n\(end)"
        // Validate profile blocks before changing any files.
        let bashProfile = [".bash_profile", ".bash_login", ".profile"].first {
            fm.fileExists(atPath: home.appendingPathComponent($0).path)
        } ?? ".bash_profile"
        let profiles = [".zprofile", bashProfile]
        var updates: [(URL, String)] = []
        for name in profiles {
            let url = home.appendingPathComponent(name).resolvingSymlinksInPath()
            var text = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
            if let start = text.range(of: begin) {
                guard let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { throw NSError(domain: "Malformed iRecord PATH block in \(name)", code: 1) }
                var range = start.lowerBound..<stop.upperBound
                if text[range.upperBound...].hasPrefix("\n") { range = range.lowerBound..<text.index(after: range.upperBound) }
                text.removeSubrange(range)
            }
            if command == "install" { if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }; text += block + "\n" }
            updates.append((url, text))
        }
        if command == "install" {
            guard app.pathExtension == "app", fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/iRecord").path) else {
                finish(ControlReply("invalid_bundle", "Run install from iRecord.app/Contents/Helpers/irecord."))
            }
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        }
        if old != nil { try fm.removeItem(at: linkURL) }
        if command == "install" { try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target) }
        for (url, text) in updates {
            if fm.fileExists(atPath: url.path) || !text.isEmpty { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        finish(ControlReply("ok", command == "install" ? "Installed. Open a new terminal or run: export PATH=\"$HOME/.local/bin:$PATH\"" : "CLI removed. App and recordings are unchanged.", values: ["command_path": linkURL.path, "app_path": app.path]))
    } catch { finish(ControlReply("install_failed", error.localizedDescription)) }
}
var connection: Int32?
do { connection = try ControlSocket.connectClient() } catch {
    guard app.pathExtension == "app", fm.fileExists(atPath: app.path) else { finish(ControlReply("app_not_found", "Run the CLI bundled in iRecord.app.")) }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.irecord.app")
    if !running.isEmpty {
        finish(ControlReply("app_unavailable", "iRecord is running but its CLI service is unavailable. Restart the updated App when no recording is active."))
    }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-g", app.path]
    do { try process.run(); process.waitUntilExit() } catch { finish(ControlReply("launch_failed", error.localizedDescription)) }
    let deadline = Date().addingTimeInterval(10)
    while connection == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.1); connection = try? ControlSocket.connectClient() }
}
guard let fd = connection else { finish(ControlReply("app_unavailable", "App did not start its CLI service within 10 seconds.")) }
defer { close(fd) }
do {
    try ControlSocket.send(ControlRequest(command: command, options: options), to: fd)
    finish(try ControlSocket.receive(ControlReply.self, from: fd))
} catch { finish(ControlReply("transport_error", error.localizedDescription + ". Query status before retrying; the operation may still be running.")) }
