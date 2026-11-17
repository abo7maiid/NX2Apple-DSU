import Foundation
import CoreGraphics
import ShellUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cemuhook UDP (DSU Controller, protocol v1001, default port 26760) client for the iOS shell (`frontend-ios`).
/// Polls a remote or local DSU server (or receives pushed controller packets after subscribing with `0x100002`)
/// and feeds shell navigation (`PadState`), controller status (`ConnectedController`), and the button test (`PadSnapshot`).
public final class DsuShellClient: @unchecked Sendable {
    public static let defaultPort: UInt16 = 26760
    public static let protocolVersion: UInt16 = 1001
    private static let magicClient: [UInt8] = [0x44, 0x53, 0x55, 0x43] // "DSUC"
    private static let magicServer: [UInt8] = [0x44, 0x53, 0x55, 0x53] // "DSUS"
    private static let msgPorts: UInt32 = 0x00100001
    private static let msgData: UInt32 = 0x00100002

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    public static func crc32(_ bytes: UnsafeRawBufferPointer, skipRange: Range<Int>? = nil) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for i in 0..<bytes.count {
            let b: UInt8 = (skipRange?.contains(i) == true) ? 0 : bytes[i]
            let idx = Int((c ^ UInt32(b)) & 0xFF)
            c = crcTable[idx] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }

    public struct SlotPacket: Equatable, Sendable {
        public var slot: Int
        public var connected: Bool
        public var model: UInt8
        public var connectionType: UInt8
        public var batteryStatus: UInt8
        public var packetNumber: UInt32
        public var padState: PadState
        public var snapshot: PadSnapshot
        public var timestampUs: UInt64
        public var accelG: (Float, Float, Float)
        public var gyroDps: (Float, Float, Float)

        public static func == (lhs: SlotPacket, rhs: SlotPacket) -> Bool {
            lhs.slot == rhs.slot &&
            lhs.connected == rhs.connected &&
            lhs.model == rhs.model &&
            lhs.connectionType == rhs.connectionType &&
            lhs.batteryStatus == rhs.batteryStatus &&
            lhs.packetNumber == rhs.packetNumber &&
            lhs.padState == rhs.padState &&
            lhs.snapshot == rhs.snapshot &&
            lhs.timestampUs == rhs.timestampUs &&
            lhs.accelG == rhs.accelG &&
            lhs.gyroDps == rhs.gyroDps
        }
    }

    /// Encode a 32-byte Cemuhook `0x100002` controller data subscription request (all 4 slots).
    public static func makeDataRequest(clientId: UInt32, slot: UInt8? = nil) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: 32)
        pkt[0...3] = magicClient[0...3]
        writeU16LE(&pkt, at: 4, value: protocolVersion)
        writeU16LE(&pkt, at: 6, value: 16) // payload after 16-byte header
        writeU32LE(&pkt, at: 12, value: clientId)
        writeU32LE(&pkt, at: 16, value: msgData)
        if let slot {
            pkt[20] = 1 // slot-based registration
            pkt[21] = slot & 0x03
        } else {
            pkt[20] = 0 // subscribe to all controllers
        }
        let crc = pkt.withUnsafeBytes { crc32($0, skipRange: 8..<12) }
        writeU32LE(&pkt, at: 8, value: crc)
        return pkt
    }

    /// Parse a Cemuhook `0x100002` `DSUS` controller data packet.
    public static func parseDataPacket(_ data: Data) -> SlotPacket? {
        guard data.count >= 100 else { return nil }
        return data.withUnsafeBytes { raw -> SlotPacket? in
            guard raw[0] == magicServer[0], raw[1] == magicServer[1],
                  raw[2] == magicServer[2], raw[3] == magicServer[3] else { return nil }
            let ver = readU16LE(raw, at: 4)
            let payloadLen = Int(readU16LE(raw, at: 6))
            guard ver == protocolVersion, payloadLen + 16 <= raw.count else { return nil }
            let packetView = UnsafeRawBufferPointer(rebasing: raw[0..<(payloadLen + 16)])
            let expectedCrc = readU32LE(raw, at: 8)
            guard crc32(packetView, skipRange: 8..<12) == expectedCrc else { return nil }
            let msgType = readU32LE(raw, at: 16)
            guard msgType == msgData else { return nil }

            let slot = Int(raw[20])
            guard (0..<4).contains(slot) else { return nil }
            let state = raw[21]
            let model = raw[22]
            let conn = raw[23]
            let battery = raw[30]
            let active = state == 2 && raw[31] != 0
            let pktNum = readU32LE(raw, at: 32)

            let b1 = raw[36]
            let b2 = raw[37]
            let homePs = raw[38]

            let lx = (Float(raw[40]) - 128.0) / 128.0
            let ly = (Float(raw[41]) - 128.0) / 128.0
            let rx = (Float(raw[42]) - 128.0) / 128.0
            let ry = (Float(raw[43]) - 128.0) / 128.0

            let l2Val = Double(raw[50]) / 255.0
            let r2Val = Double(raw[51]) / 255.0

            var padButtons: Set<PadButton> = []
            var elements: Set<PadElement> = []

            let dpadLeft = (b1 & 0x80) != 0 || raw[44] > 128
            let dpadDown = (b1 & 0x40) != 0 || raw[45] > 128
            let dpadRight = (b1 & 0x20) != 0 || raw[46] > 128
            let dpadUp = (b1 & 0x10) != 0 || raw[47] > 128
            if dpadLeft { elements.insert(.left) }
            if dpadDown { elements.insert(.down) }
            if dpadRight { elements.insert(.right) }
            if dpadUp { elements.insert(.up) }

            let optionsPlus = (b1 & 0x08) != 0
            let r3 = (b1 & 0x04) != 0
            let l3 = (b1 & 0x02) != 0
            let shareMinus = (b1 & 0x01) != 0

            // Cemuhook bitmask2: 0x80 Y/Square, 0x40 B/Cross (south), 0x20 A/Circle (east), 0x10 X/Triangle (north)
            // In ShellControllers, PadButton.a is confirm (Switch A / east; Xbox A / south). For DSU controllers,
            // East (0x20) is Switch A and South (0x40) is Switch B.
            let faceWest = (b2 & 0x80) != 0 || raw[55] > 128
            let faceSouth = (b2 & 0x40) != 0 || raw[53] > 128
            let faceEast = (b2 & 0x20) != 0 || raw[52] > 128
            let faceNorth = (b2 & 0x10) != 0 || raw[54] > 128
            let r1 = (b2 & 0x08) != 0 || raw[48] > 128
            let l1 = (b2 & 0x04) != 0 || raw[49] > 128
            let r2 = (b2 & 0x02) != 0 || raw[51] > 64
            let l2 = (b2 & 0x01) != 0 || raw[50] > 64
            let home = (homePs & 0x01) != 0

            if faceEast { padButtons.insert(.a); elements.insert(.b) }
            if faceSouth { padButtons.insert(.b); elements.insert(.a) }
            if faceNorth { padButtons.insert(.x); elements.insert(.y) }
            if faceWest { padButtons.insert(.y); elements.insert(.x) }
            if optionsPlus { padButtons.insert(.menu); elements.insert(.menu) }
            if shareMinus { padButtons.insert(.options); elements.insert(.view) }
            if l1 { padButtons.insert(.leftShoulder); elements.insert(.leftBumper) }
            if r1 { padButtons.insert(.rightShoulder); elements.insert(.rightBumper) }
            if l2 { elements.insert(.leftTrigger) }
            if r2 { elements.insert(.rightTrigger) }
            if l3 { elements.insert(.leftStick) }
            if r3 { elements.insert(.rightStick) }
            if home { elements.insert(.home) }

            let dpadX: Float = dpadRight ? 1 : (dpadLeft ? -1 : 0)
            let dpadY: Float = dpadUp ? 1 : (dpadDown ? -1 : 0)
            let navX = dpadX != 0 ? dpadX : max(-1, min(1, lx))
            let navY = dpadY != 0 ? dpadY : max(-1, min(1, ly))

            let ts = readU64LE(raw, at: 68)
            let ax = readF32LE(raw, at: 76)
            let ay = readF32LE(raw, at: 80)
            let az = readF32LE(raw, at: 84)
            let pitch = readF32LE(raw, at: 88)
            let yaw = readF32LE(raw, at: 92)
            let roll = readF32LE(raw, at: 96)

            let name = "DSU Controller \(slot + 1)"
            let snap = PadSnapshot(
                name: name,
                pressed: active ? elements : [],
                leftStick: active ? CGPoint(x: Double(max(-1, min(1, lx))), y: Double(max(-1, min(1, ly)))) : .zero,
                rightStick: active ? CGPoint(x: Double(max(-1, min(1, rx))), y: Double(max(-1, min(1, ry)))) : .zero,
                leftTrigger: active ? l2Val : 0,
                rightTrigger: active ? r2Val : 0
            )
            let pState = active ? PadState(x: navX, y: navY, buttons: padButtons) : PadState()

            return SlotPacket(
                slot: slot,
                connected: active,
                model: model,
                connectionType: conn,
                batteryStatus: battery,
                packetNumber: pktNum,
                padState: pState,
                snapshot: snap,
                timestampUs: ts,
                accelG: (ax, ay, az),
                gyroDps: (pitch, yaw, roll)
            )
        }
    }

    public static func batteryInfo(for status: UInt8) -> (percent: Int?, charging: Bool) {
        switch status {
        case 0x01: return (5, false)
        case 0x02: return (20, false)
        case 0x03: return (55, false)
        case 0x04: return (85, false)
        case 0x05: return (100, false)
        case 0xEE: return (75, true)
        case 0xEF: return (100, true)
        default: return (nil, false)
        }
    }

    // MARK: - Live UDP Transport (Port 26760)

    public var onSlotPacket: ((SlotPacket) -> Void)?
    public var onSlotsChanged: (([Int: SlotPacket]) -> Void)?

    private var socketFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timerSource: DispatchSourceTimer?
    private var serverAddrs: [sockaddr_in] = []
    private let clientId = UInt32.random(in: 1...UInt32.max)
    private var slots: [Int: SlotPacket] = [:]
    private var peerKeys: [Int: String] = [:]
    private var lastRxTime: [Int: TimeInterval] = [:]
    private let timeoutSeconds: TimeInterval = 2.5

    public init() {}

    deinit {
        stop()
    }

    public var activeSlots: [SlotPacket] {
        slots.values.filter(\.connected).sorted { $0.slot < $1.slot }
    }

    public func start(enabled: Bool = true, hosts: [String] = [], port: UInt16 = DsuShellClient.defaultPort) {
        let joined = hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ",")
        if !enabled {
            stop()
            return
        }
        start(host: joined.isEmpty ? nil : joined, port: port)
    }

    public func start(host: String? = nil, port: UInt16 = DsuShellClient.defaultPort) {
        stop()
        let envSpec = ProcessInfo.processInfo.environment["DM_DSU"]
        if host == nil, let envSpec, envSpec == "0" || envSpec.lowercased() == "off" {
            return
        }
        var targetPort = port
        if let envPort = ProcessInfo.processInfo.environment["DM_DSU_PORT"],
           let parsedPort = UInt16(envPort), parsedPort > 0 {
            targetPort = parsedPort
        }
        let spec = (host ?? envSpec ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var endpoints: [(host: String, port: UInt16)] = []
        let passiveBind = true
        if spec.isEmpty || spec == "1" || spec.lowercased() == "on" || spec.lowercased() == "auto" {
            endpoints.append(("127.0.0.1", targetPort))
        } else if spec == "0" || spec.lowercased() == "off" {
            return
        } else {
            for rawPart in spec.split(separator: ",").prefix(4) {
                let raw = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                if let colon = raw.lastIndex(of: ":"), colon != raw.startIndex {
                    let h = String(raw[..<colon])
                    let p = UInt16(raw[raw.index(after: colon)...]) ?? targetPort
                    endpoints.append((h, p > 0 ? p : targetPort))
                } else {
                    endpoints.append((raw, targetPort))
                }
            }
            if endpoints.isEmpty {
                endpoints.append(("127.0.0.1", targetPort))
            }
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var bindAddr = sockaddr_in()
        #if canImport(Darwin)
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_addr.s_addr = INADDR_ANY.bigEndian
        bindAddr.sin_port = (passiveBind ? targetPort : 0).bigEndian
        let bindRes = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRes < 0 && passiveBind {
            bindAddr.sin_port = 0
            _ = withUnsafePointer(to: &bindAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        serverAddrs = endpoints.compactMap { ep in
            var addr = sockaddr_in()
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = ep.port.bigEndian
            guard inet_pton(AF_INET, ep.host, &addr.sin_addr) == 1 else { return nil }
            return addr
        }

        socketFd = fd
        let rSrc = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        rSrc.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        rSrc.setCancelHandler {
            close(fd)
        }
        readSource = rSrc
        rSrc.resume()

        let tSrc = DispatchSource.makeTimerSource(queue: .main)
        tSrc.schedule(deadline: .now(), repeating: .milliseconds(1500))
        tSrc.setEventHandler { [weak self] in
            self?.sendSubscription()
            self?.checkTimeouts()
        }
        timerSource = tSrc
        tSrc.resume()

        sendSubscription()
    }

    public func stop() {
        timerSource?.cancel()
        timerSource = nil
        if let readSource {
            readSource.cancel()
            self.readSource = nil
        } else if socketFd >= 0 {
            close(socketFd)
        }
        socketFd = -1
        serverAddrs.removeAll()
        peerKeys.removeAll()
        if !slots.isEmpty {
            slots.removeAll()
            lastRxTime.removeAll()
            onSlotsChanged?([:])
        }
    }

    private func sendSubscription() {
        guard socketFd >= 0, !serverAddrs.isEmpty else { return }
        let req = Self.makeDataRequest(clientId: clientId, slot: nil)
        for addr in serverAddrs {
            var dst = addr
            req.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                withUnsafePointer(to: &dst) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = sendto(socketFd, base, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func resolveLocalSlot(peerIP: UInt32, remoteSlot: Int, connected: Bool) -> Int? {
        let key = "\(peerIP):\(remoteSlot)"
        if let existing = peerKeys.first(where: { $0.value == key })?.key {
            return existing
        }
        guard connected else { return nil }
        if slots[remoteSlot]?.connected != true {
            peerKeys[remoteSlot] = key
            return remoteSlot
        }
        for i in 0..<4 where slots[i]?.connected != true {
            peerKeys[i] = key
            return i
        }
        return nil
    }

    private func drainSocket() {
        guard socketFd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 512)
        for _ in 0..<64 {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(socketFd, base, raw.count, 0, sa, &fromLen)
                    }
                }
            }
            if n <= 0 { break }
            if serverAddrs.isEmpty && from.sin_family == sa_family_t(AF_INET) {
                serverAddrs.append(from)
            }
            guard var pkt = Self.parseDataPacket(Data(buf[0..<n])) else { continue }
            let peerIP = from.sin_family == sa_family_t(AF_INET) ? UInt32(from.sin_addr.s_addr) : 0
            guard let localSlot = resolveLocalSlot(peerIP: peerIP, remoteSlot: pkt.slot, connected: pkt.connected) else { continue }
            pkt.slot = localSlot
            pkt.snapshot = PadSnapshot(
                name: "DSU Controller \(localSlot + 1)",
                pressed: pkt.snapshot.pressed,
                leftStick: pkt.snapshot.leftStick,
                rightStick: pkt.snapshot.rightStick,
                leftTrigger: pkt.snapshot.leftTrigger,
                rightTrigger: pkt.snapshot.rightTrigger
            )
            let now = ProcessInfo.processInfo.systemUptime
            let wasConnected = slots[localSlot]?.connected == true
            if pkt.connected {
                slots[localSlot] = pkt
                lastRxTime[localSlot] = now
                onSlotPacket?(pkt)
                if !wasConnected {
                    onSlotsChanged?(slots)
                }
            } else if wasConnected {
                slots.removeValue(forKey: localSlot)
                peerKeys.removeValue(forKey: localSlot)
                lastRxTime.removeValue(forKey: localSlot)
                onSlotPacket?(pkt)
                onSlotsChanged?(slots)
            }
        }
    }

    private func checkTimeouts() {
        let now = ProcessInfo.processInfo.systemUptime
        var changed = false
        for (slot, ts) in lastRxTime where now - ts > timeoutSeconds {
            lastRxTime.removeValue(forKey: slot)
            peerKeys.removeValue(forKey: slot)
            if var old = slots.removeValue(forKey: slot) {
                old.connected = false
                old.padState = PadState()
                old.snapshot = PadSnapshot(name: old.snapshot.name, pressed: [], leftStick: .zero, rightStick: .zero, leftTrigger: 0, rightTrigger: 0)
                onSlotPacket?(old)
                changed = true
            }
        }
        if changed {
            onSlotsChanged?(slots)
        }
    }

    private static func writeU16LE(_ buf: inout [UInt8], at offset: Int, value: UInt16) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func writeU32LE(_ buf: inout [UInt8], at offset: Int, value: UInt32) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func readU16LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    private static func readU32LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(raw[offset]) |
        (UInt32(raw[offset + 1]) << 8) |
        (UInt32(raw[offset + 2]) << 16) |
        (UInt32(raw[offset + 3]) << 24)
    }

    private static func readU64LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        UInt64(readU32LE(raw, at: offset)) | (UInt64(readU32LE(raw, at: offset + 4)) << 32)
    }

    private static func readF32LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Float {
        Float(bitPattern: readU32LE(raw, at: offset))
    }
}
