import CoreGraphics
import Foundation

/// One framebuffer from the guest, packed as 8-bit RGBA.
public struct VNCFrame: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

struct VNCPixelFormat: Equatable, Sendable {
    var bitsPerPixel: Int
    var depth: Int
    var bigEndian: Bool
    var trueColor: Bool
    var redMax: Int
    var greenMax: Int
    var blueMax: Int
    var redShift: Int
    var greenShift: Int
    var blueShift: Int

    var bytesPerPixel: Int { bitsPerPixel / 8 }
}

/// Parses an RFB 3.8 session and returns the bytes the client must send.
///
/// QEMU's VNC server speaks this. The parser accepts raw rectangles and a
/// desktop resize, and expands each pixel to RGBA.
public final class VNCParser {
    public private(set) var frame = VNCFrame(width: 0, height: 0, pixels: Data())
    private(set) var format: VNCPixelFormat?

    public init() {}
    private var buffer = Data()
    private var phase = Phase.banner
    private var rectangleCount = 0
    private var rawRemaining = 0
    private var rawOrigin = 0
    private var rawX = 0
    private var rawY = 0
    private var rawWidth = 0
    private var rawRow = 0
    private var rawRowFilled = 0

    public func consume(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var outgoing: [Data] = []
        var progressed = true
        while progressed {
            progressed = false
            switch phase {
            case .banner:
                guard buffer.count >= 12 else { return outgoing }
                let banner = buffer.prefix(12)
                guard banner.starts(with: Data("RFB 003.".utf8)), banner.last == 0x0A else {
                    throw VNCError.protocol("the display server did not offer RFB")
                }
                buffer.removeFirst(12)
                outgoing.append(Data("RFB 003.008\n".utf8))
                phase = .securityCount
                progressed = true
            case .securityCount:
                guard let count = take(1) else { return outgoing }
                if count[0] == 0 { throw VNCError.protocol("the display server refused the connection") }
                phase = .securityTypes(Int(count[0]))
                progressed = true
            case .securityTypes(let count):
                guard buffer.count >= count else { return outgoing }
                let types = buffer.prefix(count)
                buffer.removeFirst(count)
                guard types.contains(1) else { throw VNCError.protocol("the display server requires authentication") }
                outgoing.append(Data([1]))
                phase = .securityResult
                progressed = true
            case .securityResult:
                guard let result = take(4) else { return outgoing }
                guard result == Data([0, 0, 0, 0]) else { throw VNCError.protocol("the display server rejected the session") }
                outgoing.append(Data([1]))
                phase = .serverInit
                progressed = true
            case .serverInit:
                guard buffer.count >= 24 else { return outgoing }
                let header = buffer.prefix(24)
                let width = int16(header, 0)
                let height = int16(header, 2)
                let format = pixelFormat(Data(header.dropFirst(4).prefix(16)))
                let nameLength = int32(header, 20)
                guard width > 0, height > 0, format.bitsPerPixel == 32, format.trueColor, nameLength >= 0,
                      nameLength < 4096 else {
                    throw VNCError.protocol("the display description is not a 32-bit framebuffer")
                }
                buffer.removeFirst(24)
                self.format = format
                frame = VNCFrame(width: width, height: height, pixels: Data(count: width * height * 4))
                phase = .serverName(nameLength)
                progressed = true
            case .serverName(let length):
                guard buffer.count >= length else { return outgoing }
                buffer.removeFirst(length)
                outgoing.append(encodings())
                outgoing.append(updateRequest(incremental: false))
                phase = .message
                progressed = true
            case .message:
                guard let kind = take(1) else { return outgoing }
                switch kind[0] {
                case 0:
                    phase = .updateHeader
                case 2:
                    phase = .message
                case 3:
                    phase = .cutHeader
                default:
                    throw VNCError.protocol("unexpected display message \(kind[0])")
                }
                progressed = true
            case .updateHeader:
                guard buffer.count >= 3 else { return outgoing }
                rectangleCount = int16(buffer, 1)
                buffer.removeFirst(3)
                phase = rectangleCount == 0 ? .message : .rectangle
                progressed = true
            case .rectangle:
                guard buffer.count >= 12 else { return outgoing }
                let x = int16(buffer, 0)
                let y = int16(buffer, 2)
                let width = int16(buffer, 4)
                let height = int16(buffer, 6)
                let encoding = signedInt32(buffer, 8)
                buffer.removeFirst(12)
                if encoding == -223 {
                    guard width > 0, height > 0, width <= 4096, height <= 4096 else {
                        throw VNCError.protocol("the display size is not usable")
                    }
                    if width != frame.width || height != frame.height {
                        frame = VNCFrame(width: width, height: height, pixels: Data(count: width * height * 4))
                    }
                    rectangleCount -= 1
                    phase = rectangleCount == 0 ? .message : .rectangle
                    if phase == .message { outgoing.append(updateRequest(incremental: false)) }
                    progressed = true
                    break
                }
                rawX = x
                rawY = y
                rawWidth = width
                guard encoding == 0, let format, rawWidth > 0, height > 0,
                      rawX >= 0, rawY >= 0, rawX + rawWidth <= frame.width, rawY + height <= frame.height else {
                    throw VNCError.protocol("the display sent a rectangle this client cannot draw")
                }
                rawRemaining = rawWidth * height * format.bytesPerPixel
                rawRow = 0
                rawRowFilled = 0
                rawOrigin = rawY
                phase = .raw
                progressed = true
            case .raw:
                guard let format else { return outgoing }
                let rowBytes = rawWidth * format.bytesPerPixel
                while rawRemaining > 0, buffer.count >= format.bytesPerPixel, rawRowFilled < rowBytes {
                    let takeCount = min(buffer.count - (buffer.count % format.bytesPerPixel), rowBytes - rawRowFilled)
                    guard takeCount > 0 else { return outgoing }
                    paint(buffer.prefix(takeCount), format: format, rowFilled: rawRowFilled)
                    buffer.removeFirst(takeCount)
                    rawRemaining -= takeCount
                    rawRowFilled += takeCount
                    if rawRowFilled == rowBytes {
                        rawRowFilled = 0
                        rawRow += 1
                    }
                }
                if rawRemaining == 0 {
                    rectangleCount -= 1
                    phase = rectangleCount == 0 ? .message : .rectangle
                    if phase == .message { outgoing.append(updateRequest(incremental: true)) }
                    progressed = true
                } else {
                    return outgoing
                }
            case .cutHeader:
                guard buffer.count >= 7 else { return outgoing }
                let length = int32(buffer, 3)
                buffer.removeFirst(7)
                guard length >= 0, length < 1 << 20 else { throw VNCError.protocol("the clipboard message is invalid") }
                phase = .cutBody(length)
                progressed = true
            case .cutBody(let length):
                guard buffer.count >= length else { return outgoing }
                buffer.removeFirst(length)
                phase = .message
                progressed = true
            }
        }
        return outgoing
    }

    public func pointer(x: Int, y: Int, buttons: UInt8) -> Data {
        var data = Data([5, buttons])
        data.appendU16(x)
        data.appendU16(y)
        return data
    }

    /// The whole framebuffer. virtio-gpu often reports no changed region after
    /// the firmware logo, so an incremental request leaves that logo on screen.
    public func fullFrameRequest() -> Data? {
        guard case .message = phase, frame.width > 0, frame.height > 0 else { return nil }
        return updateRequest(incremental: false)
    }

    public func key(keysym: UInt32, down: Bool) -> Data {
        var data = Data([4, down ? 1 : 0, 0, 0])
        data.append(contentsOf: [
            UInt8((keysym >> 24) & 0xFF),
            UInt8((keysym >> 16) & 0xFF),
            UInt8((keysym >> 8) & 0xFF),
            UInt8(keysym & 0xFF),
        ])
        return data
    }

    private func encodings() -> Data {
        var data = Data([2, 0])
        data.appendU16(2)
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x21])
        return data
    }

    private func updateRequest(incremental: Bool) -> Data {
        var data = Data([3, incremental ? 1 : 0])
        data.appendU16(0)
        data.appendU16(0)
        data.appendU16(frame.width)
        data.appendU16(frame.height)
        return data
    }

    private func paint(_ row: Data.SubSequence, format: VNCPixelFormat, rowFilled: Int) {
        var source = 0
        var filled = rowFilled
        let bytes = [UInt8](row)
        while source + format.bytesPerPixel <= bytes.count {
            let pixel = loadPixel(bytes, source, format: format)
            let rgba = rgba(pixel, format: format)
            let y = rawOrigin + rawRow
            let x = rawX + filled / format.bytesPerPixel
            let destination = (y * frame.width + x) * 4
            guard destination >= 0, destination + 4 <= frame.pixels.count else {
                source += format.bytesPerPixel
                filled += format.bytesPerPixel
                continue
            }
            frame.pixels.replaceSubrange(destination..<(destination + 4), with: rgba)
            source += format.bytesPerPixel
            filled += format.bytesPerPixel
        }
    }

    private func loadPixel(_ bytes: [UInt8], _ offset: Int, format: VNCPixelFormat) -> UInt32 {
        let slice = bytes[offset..<(offset + 4)]
        let ordered = format.bigEndian ? Array(slice) : Array(slice.reversed())
        return ordered.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func rgba(_ pixel: UInt32, format: VNCPixelFormat) -> [UInt8] {
        func channel(_ shift: Int, _ max: Int) -> UInt8 {
            guard max > 0 else { return 0 }
            let value = Int((pixel >> shift) & UInt32(max))
            return UInt8((value * 255) / max)
        }
        return [
            channel(format.redShift, format.redMax),
            channel(format.greenShift, format.greenMax),
            channel(format.blueShift, format.blueMax),
            255,
        ]
    }

    private func pixelFormat(_ bytes: Data) -> VNCPixelFormat {
        VNCPixelFormat(
            bitsPerPixel: Int(bytes[0]),
            depth: Int(bytes[1]),
            bigEndian: bytes[2] != 0,
            trueColor: bytes[3] != 0,
            redMax: int16(bytes, 4),
            greenMax: int16(bytes, 6),
            blueMax: int16(bytes, 8),
            redShift: Int(bytes[10]),
            greenShift: Int(bytes[11]),
            blueShift: Int(bytes[12])
        )
    }

    private func take(_ count: Int) -> Data? {
        guard buffer.count >= count else { return nil }
        let prefix = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return prefix
    }

    private func int16(_ data: any DataProtocol, _ offset: Int) -> Int {
        let bytes = [UInt8](data)
        return (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    private func int32(_ data: any DataProtocol, _ offset: Int) -> Int {
        let bytes = [UInt8](data)
        return (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }

    private func signedInt32(_ data: any DataProtocol, _ offset: Int) -> Int {
        let bytes = [UInt8](data)
        let raw = (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        return Int(Int32(bitPattern: raw))
    }

    private enum Phase: Equatable {
        case banner
        case securityCount
        case securityTypes(Int)
        case securityResult
        case serverInit
        case serverName(Int)
        case message
        case updateHeader
        case rectangle
        case raw
        case cutHeader
        case cutBody(Int)
    }
}

public enum VNCError: Error, Equatable, CustomStringConvertible {
    case `protocol`(String)
    public var description: String { switch self { case .protocol(let detail): detail } }
}

private extension Data {
    mutating func appendU16(_ value: Int) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

/// Where a touch lands in the guest framebuffer when the frame is fitted inside the view.
public enum DisplayMapping {
    public static func fittedSize(viewSize: CGSize, frameSize: CGSize) -> CGSize {
        guard viewSize.width > 0, viewSize.height > 0, frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / frameSize.width, viewSize.height / frameSize.height)
        return CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
    }

    public static func framebufferPoint(viewSize: CGSize, frameSize: CGSize, location: CGPoint) -> (Int, Int)? {
        guard viewSize.width > 0, viewSize.height > 0, frameSize.width > 0, frameSize.height > 0 else { return nil }
        let fitted = fittedSize(viewSize: viewSize, frameSize: frameSize)
        let scale = fitted.width / frameSize.width
        let origin = CGPoint(x: (viewSize.width - fitted.width) / 2, y: (viewSize.height - fitted.height) / 2)
        let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        guard local.x >= 0, local.y >= 0, local.x < fitted.width, local.y < fitted.height else { return nil }
        let x = min(Int(frameSize.width) - 1, Int(local.x / scale))
        let y = min(Int(frameSize.height) - 1, Int(local.y / scale))
        return (x, y)
    }
}

/// USB HID keyboard usages the guest receives as X11 keysyms.
public enum GuestKey {
    public static func keysym(hidUsage: Int) -> UInt32? {
        if (0x04...0x1D).contains(hidUsage) { return UInt32(0x61 + hidUsage - 0x04) }
        if (0x1E...0x26).contains(hidUsage) { return UInt32(0x31 + hidUsage - 0x1E) }
        if hidUsage == 0x27 { return 0x30 }
        switch hidUsage {
        case 0x28: return 0xFF0D
        case 0x29: return 0xFF1B
        case 0x2A: return 0xFF08
        case 0x2B: return 0xFF09
        case 0x2C: return 0x20
        case 0x4F: return 0xFF53
        case 0x50: return 0xFF51
        case 0x51: return 0xFF54
        case 0x52: return 0xFF52
        case 0xE0: return 0xFFE3
        case 0xE1: return 0xFFE1
        case 0xE2: return 0xFFE9
        case 0xE3: return 0xFFEB
        default: return nil
        }
    }
}
