// SPDX-License-Identifier: MIT
// Adapted from Atoll (https://github.com/rutmehta/Atoll) at 537ad7d: Features/Agents/AgentSocketServer.swift.
// Copyright (c) 2026 Rut Mehta. MIT License; see THIRD_PARTY_NOTICES.md.
import Darwin
import Foundation

/// Topdeck's end of the approval hook: a Unix socket in Topdeck's Application Support folder, readable
/// and writable by this user only. The hook script sends one request and waits; Topdeck holds the
/// connection until the user answers in the notch, then writes the decision back and closes it.
/// Closing without writing, which is what every failure, refusal, and timeout does, leaves the hook
/// with nothing to print, and the agent asks in its own prompt. All state lives on one serial queue;
/// callbacks arrive on the main queue.
final class AgentSocket: @unchecked Sendable {
    enum StartError: Error, Equatable {
        /// Longer than a socket address holds.
        case pathTooLong
        /// Another Topdeck answers on it.
        case inUse
        /// Something that isn't a socket sits at the path; it's never removed.
        case occupied
        /// Its permissions or owner aren't what was set.
        case insecure
        case failed(Int32)
    }

    let path: URL
    /// How long a request waits for the user before the agent's own prompt takes over.
    let holdLimit: TimeInterval
    /// How long a hook gets to send its request.
    let readLimit: TimeInterval
    private let onRequest: @MainActor @Sendable (AgentRequest) -> Void
    private let onGone: @MainActor @Sendable (UUID) -> Void

    private let queue = DispatchQueue(label: "Topdeck.AgentSocket")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var held: [UUID: Connection] = [:]

    /// One hook's connection: first reading its request, then held until it's answered.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        var source: DispatchSourceRead?
        var timer: DispatchSourceTimer?
        var buffer = Data()
        var header: (tool: AgentTool, length: Int)?
        var request: UUID?

        init(fd: Int32) { self.fd = fd }
    }

    /// `onRequest` gets each request that passed every check; `onGone` a held one whose hook stopped
    /// waiting, timed out, or quit before it was answered.
    init(
        path: URL, holdLimit: TimeInterval, readLimit: TimeInterval = 5,
        onRequest: @escaping @MainActor @Sendable (AgentRequest) -> Void,
        onGone: @escaping @MainActor @Sendable (UUID) -> Void
    ) {
        self.path = path
        self.holdLimit = holdLimit
        self.readLimit = readLimit
        self.onRequest = onRequest
        self.onGone = onGone
    }

    deinit {
        // Nothing else holds the socket now, so no queue: deinit may even run on it.
        acceptSource?.cancel()
        for connection in connections.values {
            connection.timer?.cancel()
            connection.source?.cancel()
        }
        if listener >= 0 { Self.removeSocket(at: path.path) }
    }

    var isListening: Bool { queue.sync { listener >= 0 } }

    func start() throws {
        try queue.sync { try startLocked() }
    }

    /// Stops listening and lets every held hook go unanswered.
    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listener >= 0 {
                listener = -1
                Self.removeSocket(at: path.path)
            }
            for connection in Array(connections.values) { finish(connection, reply: nil, notify: false) }
        }
    }

    /// Writes the decision to a held hook and closes it. Does nothing for one that's gone.
    func reply(to id: UUID, with payload: Data) {
        queue.async { [self] in
            guard let connection = held[id] else { return }
            finish(connection, reply: payload, notify: false)
        }
    }

    /// Lets a held hook go without a decision, so the agent asks in its own prompt.
    func release(_ id: UUID) {
        queue.async { [self] in
            guard let connection = held[id] else { return }
            finish(connection, reply: nil, notify: false)
        }
    }

    // MARK: Listening

    private func startLocked() throws {
        guard listener < 0 else { return }
        let path = path.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw StartError.pathTooLong }
        var status = stat()
        if lstat(path, &status) == 0 {
            // Only ever replace a socket, and only one nobody answers on: a Topdeck that quit.
            guard status.st_mode & S_IFMT == S_IFSOCK else { throw StartError.occupied }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let answered = probe >= 0 && Self.withAddress(path) { connect(probe, $0, $1) } == 0
            if probe >= 0 { close(probe) }
            if answered { throw StartError.inUse }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.failed(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard Self.withAddress(path, { bind(fd, $0, $1) }) == 0 else {
            let error = errno
            close(fd)
            throw StartError.failed(error)
        }
        // Owner only, checked, before anyone can connect: until `listen`, connecting is refused.
        guard chmod(path, 0o600) == 0, lstat(path, &status) == 0, status.st_mode & 0o777 == 0o600,
            status.st_uid == getuid()
        else {
            close(fd)
            unlink(path)
            throw StartError.insecure
        }
        guard listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            unlink(path)
            throw StartError.failed(error)
        }
        Self.setNonBlocking(fd)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    private func acceptAll() {
        while listener >= 0 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            // The socket's permissions already keep other users out; this checks it again.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            Self.setNonBlocking(fd)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                readAvailable(connection)
            }
            source.setCancelHandler { close(fd) }
            connection.source = source
            connection.timer = timer(after: readLimit) { [weak self, weak connection] in
                guard let self, let connection else { return }
                finish(connection, reply: nil, notify: true)
            }
            connections[fd] = connection
            source.resume()
        }
    }

    private func timer(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: fire)
        timer.resume()
        return timer
    }

    // MARK: Reading

    private func readAvailable(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var ended = false
        while true {
            let count = read(connection.fd, &chunk, chunk.count)
            if count > 0 {
                connection.buffer.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                ended = count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)
                break
            }
        }
        // A held hook only ever waits; anything it says, or its hanging up, ends it.
        if connection.request != nil {
            if ended || !connection.buffer.isEmpty { finish(connection, reply: nil, notify: true) }
            return
        }
        switch Self.request(from: &connection.buffer, header: &connection.header) {
        case .incomplete:
            if ended { finish(connection, reply: nil, notify: false) }
        case .invalid:
            finish(connection, reply: nil, notify: false)
        case .complete(let request):
            connection.request = request.id
            connection.buffer = Data()
            connection.timer?.cancel()
            connection.timer = timer(after: holdLimit) { [weak self, weak connection] in
                guard let self, let connection else { return }
                finish(connection, reply: nil, notify: true)
            }
            held[request.id] = connection
            if ended {
                finish(connection, reply: nil, notify: false)
                return
            }
            let onRequest = onRequest
            DispatchQueue.main.async { MainActor.assumeIsolated { onRequest(request) } }
        }
    }

    enum ReadResult: Equatable {
        case incomplete, invalid
        case complete(AgentRequest)
    }

    /// Takes a request from what a hook has sent so far: a header line, then exactly the JSON it
    /// announced. Anything malformed, oversized, or followed by more bytes is invalid.
    static func request(
        from buffer: inout Data, header: inout (tool: AgentTool, length: Int)?, id: UUID = UUID()
    ) -> ReadResult {
        if header == nil {
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                return buffer.count > AgentWire.maxHeader ? .invalid : .incomplete
            }
            guard newline - buffer.startIndex <= AgentWire.maxHeader,
                let line = String(data: buffer[buffer.startIndex..<newline], encoding: .utf8),
                let parsed = AgentWire.header(line)
            else { return .invalid }
            header = parsed
            buffer = Data(buffer[(newline + 1)...])
        }
        guard let header else { return .invalid }
        if buffer.count < header.length { return .incomplete }
        guard buffer.count == header.length, let request = try? AgentRequest.parse(buffer, tool: header.tool, id: id)
        else { return .invalid }
        return .complete(request)
    }

    // MARK: Ending

    /// Closes a connection, writing `reply` first when there is one. With `notify`, a held request's
    /// card goes from the notch.
    private func finish(_ connection: Connection, reply: Data?, notify: Bool) {
        guard connections.removeValue(forKey: connection.fd) != nil else { return }
        connection.timer?.cancel()
        if let id = connection.request { held[id] = nil }
        if let reply { Self.write(reply + Data("\n".utf8), to: connection.fd) }
        connection.source?.cancel()
        if notify, let id = connection.request {
            let onGone = onGone
            DispatchQueue.main.async { MainActor.assumeIsolated { onGone(id) } }
        }
    }

    /// A short write with a deadline: blocking, so a reply goes out whole or not at all.
    private static func write(_ data: Data, to fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    // MARK: Helpers

    private static func removeSocket(at path: String) {
        var status = stat()
        if lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
    }

    private static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
