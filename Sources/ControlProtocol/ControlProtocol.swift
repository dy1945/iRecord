import Foundation
import CoreGraphics
import Darwin

public struct ControlRequest: Codable, Sendable {
    public var command: String
    public var options: [String: String]
    public init(command: String, options: [String: String]) { self.command = command; self.options = options }
}
public struct ControlReply: Codable, Sendable {
    public var ok: Bool
    public var code: String
    public var message: String
    public var values: [String: String]
    public var windows: [[String: String]]?
    public init(_ code: String = "ok", _ message: String = "", values: [String: String] = [:], windows: [[String: String]]? = nil) {
        ok = code == "ok"; self.code = code; self.message = message; self.values = values; self.windows = windows
    }
}
public enum ControlSocket {
    public static var directory: String { "/tmp/irecord-\(getuid())" }
    public static var path: String { directory + "/control.sock" }
    public static func prepareDirectory() throws {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw failure() }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw NSError(domain: "Unsafe IPC directory", code: 1)
        }
    }
    public static func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    public static func address<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
    public static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    public static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
    public static func connectClient() throws -> Int32 {
        try prepareDirectory()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure() }
        configure(fd)
        guard address({ Darwin.connect(fd, $0, $1) }) == 0, sameUser(fd) else {
            let error = failure(); close(fd); throw error
        }
        return fd
    }
    public static func send<T: Encodable>(_ value: T, to fd: Int32) throws {
        let data = try JSONEncoder().encode(value)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
        shutdown(fd, SHUT_WR)
    }
    public static func receive<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 1_048_576 else { throw NSError(domain: "IPC message too large", code: 1) }
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

public enum RecordingExportPolicy {
    public struct CropInsets: Equatable, Sendable {
        public var top: CGFloat
        public var right: CGFloat
        public var bottom: CGFloat
        public var left: CGFloat

        public init(top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
            self.top = top; self.right = right; self.bottom = bottom; self.left = left
        }

        public static func parse(_ value: String) -> CropInsets? {
            let values = value.split(separator: ",", omittingEmptySubsequences: false)
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 4, values.allSatisfy({ $0 >= 0 && $0 <= 8192 }) else { return nil }
            return CropInsets(top: values[0], right: values[1], bottom: values[2], left: values[3])
        }
    }

    public static func cropRect(_ size: CGSize, insets: CropInsets) -> CGRect? {
        let width = size.width - insets.left - insets.right
        let height = size.height - insets.top - insets.bottom
        guard width >= 2, height >= 2 else { return nil }
        return CGRect(x: insets.left, y: insets.top, width: width, height: height)
    }

    public static func pixelInsets(from points: CropInsets, sourceSize: CGSize,
                                   windowSize: CGSize) -> CropInsets? {
        guard sourceSize.width > 0, sourceSize.height > 0,
              windowSize.width > 0, windowSize.height > 0 else { return nil }
        return CropInsets(top: points.top * sourceSize.height / windowSize.height,
                          right: points.right * sourceSize.width / windowSize.width,
                          bottom: points.bottom * sourceSize.height / windowSize.height,
                          left: points.left * sourceSize.width / windowSize.width)
    }

    public static func fittedSize(_ size: CGSize, maxEdge: CGFloat) -> CGSize {
        guard maxEdge > 0, max(size.width, size.height) > maxEdge else {
            return even(size)
        }
        let scale = maxEdge / max(size.width, size.height)
        return even(CGSize(width: size.width * scale, height: size.height * scale))
    }

    private static func even(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, floor(size.width / 2) * 2),
               height: max(2, floor(size.height / 2) * 2))
    }
}
