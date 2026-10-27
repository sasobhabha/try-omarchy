import Darwin
import Foundation
import TryOmarchyCore

/// The guest framebuffer, read from QEMU's VNC server on this device.
///
/// Network.framework leaves a connection to 127.0.0.1 in `.waiting`, so the
/// screen never arrives. A local socket becomes ready as soon as QEMU listens.
final class GuestDisplay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.tryomarchy.vnc")
    private var parser = VNCParser()
    private var shown = VNCFrame(width: 0, height: 0, pixels: Data())
    private var socketFD: Int32 = -1
    private var reader: DispatchSourceRead?
    private var refresh: DispatchSourceTimer?
    private let attemptLimit = 200
    private var attempts = 0
    private var generation = 0
    var onFrame: ((VNCFrame) -> Void)?
    var onFailure: ((String) -> Void)?

    func start() {
        queue.async {
            self.invalidate()
            self.attempts = 0
            self.connect(self.generation)
        }
    }

    func stop() {
        queue.async {
            self.invalidate()
        }
    }

    func pointer(x: Int, y: Int, buttons: UInt8) {
        queue.async {
            self.send(self.parser.pointer(x: x, y: y, buttons: buttons))
        }
    }

    func key(keysym: UInt32, down: Bool) {
        queue.async {
            self.send(self.parser.key(keysym: keysym, down: down))
        }
    }

    private func connect(_ generation: Int) {
        guard generation == self.generation else { return }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            retry(generation)
            return
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(5900).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            retry(generation)
            return
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        attempts = 0
        socketFD = fd
        parser = VNCParser()
        shown = VNCFrame(width: 0, height: 0, pixels: Data())
        armRefresh(generation)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable(generation)
        }
        source.setCancelHandler {
            close(fd)
        }
        reader = source
        source.resume()
    }

    private func retry(_ generation: Int) {
        guard generation == self.generation else { return }
        attempts += 1
        releaseSocket()
        guard attempts < attemptLimit else {
            DispatchQueue.main.async { self.onFailure?("The display did not open.") }
            return
        }
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.connect(generation)
        }
    }

    private func invalidate() {
        generation += 1
        attempts = attemptLimit
        refresh?.cancel()
        refresh = nil
        releaseSocket()
    }

    private func armRefresh(_ generation: Int) {
        refresh?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(700), repeating: .milliseconds(700))
        timer.setEventHandler { [weak self] in
            guard let self, generation == self.generation else { return }
            guard let request = self.parser.fullFrameRequest() else { return }
            self.send(request)
        }
        refresh = timer
        timer.resume()
    }

    private func releaseSocket() {
        let source = reader
        reader = nil
        socketFD = -1
        source?.cancel()
    }

    private func readAvailable(_ generation: Int) {
        guard generation == self.generation, socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while socketFD >= 0 {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(self.socketFD, raw.baseAddress, raw.count)
            }
            if count > 0 {
                do {
                    var painted = false
                    for message in try parser.consume(Data(buffer.prefix(count))) {
                        send(message)
                        if message.count >= 2, message[0] == 3, message[1] == 1 {
                            painted = true
                        }
                    }
                    if painted, parser.frame.width > 0, parser.frame != shown {
                        shown = parser.frame
                        let frame = shown
                        DispatchQueue.main.async { self.onFrame?(frame) }
                    }
                } catch {
                    DispatchQueue.main.async { self.onFailure?("\(error)") }
                    invalidate()
                    return
                }
            } else if count == 0 {
                retry(generation)
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                retry(generation)
                return
            }
        }
    }

    private func send(_ data: Data) {
        let fd = socketFD
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            var waits = 0
            while sent < raw.count {
                let wrote = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if wrote > 0 {
                    sent += wrote
                    waits = 0
                    continue
                }
                if wrote < 0, errno == EAGAIN || errno == EWOULDBLOCK, waits < 20 {
                    waits += 1
                    var polled = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&polled, 1, 50)
                    continue
                }
                return
            }
        }
    }
}
