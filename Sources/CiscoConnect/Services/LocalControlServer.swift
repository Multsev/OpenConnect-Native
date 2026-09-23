import Foundation
import Darwin

/// Same-user Unix socket. The CLI never talks to the privileged helper directly.
final class LocalControlServer: @unchecked Sendable {
    static var socketDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ocnative", isDirectory: true)
    }
    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.max.ciscoconnect.control", qos: .utility)

    func start(handler: @escaping @Sendable (Data) async -> Data) throws {
        let directory = Self.socketDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw POSIXError(.EACCES)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("control.sock").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        // Refuse a second server; remove only a socket whose listener is gone.
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected == 0 { close(fd); throw POSIXError(.EADDRINUSE) }
        let connectError = errno
        guard connectError == ENOENT || connectError == ECONNREFUSED else { close(fd); throw POSIXError(.EACCES) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); throw POSIXError(.EIO)
        }
        descriptor = fd
        queue.async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
                // Bound both the read inactivity timeout and total request time.
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                let deadline = Date().addingTimeInterval(2)
                var request = Data()
                var byte: UInt8 = 0
                while Date() < deadline, request.count < 4096, recv(client, &byte, 1, 0) == 1, byte != 10 { request.append(byte) }
                guard byte == 10, !request.isEmpty else { close(client); continue }
                let payload = request
                Task {
                    let response = await handler(payload) + Data([10])
                    response.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let count = send(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                            if count <= 0 { break }
                            offset += count
                        }
                    }
                    close(client)
                }
            }
        }
    }
}
