import XCTest
import ShellUI
@testable import ShellControllers

final class PadMappingTests: XCTestCase {
    func testButtonsMapLikeTheMacConsole() {
        XCTAssertEqual(PadMapper.action(for: .a), .activate)
        XCTAssertEqual(PadMapper.action(for: .b), .back)
        XCTAssertEqual(PadMapper.action(for: .x), .settings)
        XCTAssertEqual(PadMapper.action(for: .menu), .settings)
        XCTAssertEqual(PadMapper.action(for: .y), .controllers)
        XCTAssertNil(PadMapper.action(for: .leftShoulder))
    }
    /// #1129: Options (Xbox View, PlayStation Create, Nintendo Minus) opens the shell's settings, one press one action. A pad without
    /// the button sends nothing new.
    func testOptionsOpensTheShellSettings() {
        XCTAssertEqual(PadMapper.action(for: .options), .shellSettings)
        var mapper = PadMapper()
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.options])).pressed, [.shellSettings])
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.options])).pressed, [], "held is not pressed again")
        XCTAssertEqual(mapper.changes(controller: "two", state: PadState(buttons: [.a])).pressed, [.activate])
    }
    func testDeadzoneAndStrongerAxis() {
        XCTAssertNil(PadMapper.direction(x: 0.4, y: -0.3))
        XCTAssertEqual(PadMapper.direction(x: 0.8, y: 0.6), .right)
        XCTAssertEqual(PadMapper.direction(x: -0.2, y: 0.9), .up)
        XCTAssertEqual(PadMapper.direction(x: 0.1, y: -0.7), .down)
        XCTAssertEqual(PadMapper.direction(x: -0.51, y: 0), .left)
    }
    func testOnePressOneActionPerController() {
        var mapper = PadMapper()
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.a])).pressed, [.activate])
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.a])).pressed, [], "held is not pressed again")
        XCTAssertEqual(mapper.changes(controller: "two", state: PadState(buttons: [.a])).pressed, [.activate], "another controller counts on its own")
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState()).pressed, [])
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.a])).pressed, [.activate])
    }
    func testDirectionPressAndRelease() {
        var mapper = PadMapper()
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(x: 1)).pressed, [.right])
        let released = mapper.changes(controller: "one", state: PadState(x: 0))
        XCTAssertEqual(released.released, [.right])
        mapper.reset(controller: "one")
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(x: 1)).pressed, [.right])
    }
    func testButtonRelease() {
        var mapper = PadMapper()
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.a])).released, [])
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState(buttons: [.a])).released, [], "held is not let go")
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState()).released, [.activate], "A coming up is reported")
        XCTAssertEqual(mapper.changes(controller: "one", state: PadState()).released, [])
    }
    func testRepeatTiming() {
        XCTAssertEqual(RepeatTiming.moves(heldFor: 0.2), 1)
        XCTAssertEqual(RepeatTiming.moves(heldFor: 0.4), 2)
        XCTAssertEqual(RepeatTiming.moves(heldFor: 0.52), 3)
        XCTAssertEqual(RepeatTiming.moves(heldFor: 1.0), 7)
    }
    func testFamiliesFromProductCategory() {
        XCTAssertEqual(ControllerFamily(productCategory: "DualSense"), .playStation)
        XCTAssertEqual(ControllerFamily(productCategory: "DualShock 4"), .playStation)
        XCTAssertEqual(ControllerFamily(productCategory: "Xbox One"), .xbox)
        XCTAssertEqual(ControllerFamily(productCategory: "Switch Pro Controller"), .nintendo)
        XCTAssertEqual(ControllerFamily(productCategory: "Nintendo Switch JoyCon (L/R)"), .nintendo)
        XCTAssertEqual(ControllerFamily(productCategory: "MFi"), .neutral)
        XCTAssertEqual(ControllerFamily(productCategory: nil), .neutral)
    }
    func testDsuClientPacketEncodingAndParsing() {
        let req = DsuShellClient.makeDataRequest(clientId: 0x12345678, slot: 0)
        XCTAssertEqual(req.count, 32)
        XCTAssertEqual(Array(req[0..<4]), [0x44, 0x53, 0x55, 0x43])

        // Build a synthetic 100-byte DSUS 0x100002 packet for slot 0
        var pkt = [UInt8](repeating: 0, count: 100)
        pkt[0...3] = [0x44, 0x53, 0x55, 0x53] // "DSUS"
        pkt[4] = 0xE9; pkt[5] = 0x03 // version 1001
        pkt[6] = 84; pkt[7] = 0 // payload length 84 (100 - 16)
        pkt[16] = 0x02; pkt[17] = 0x00; pkt[18] = 0x10; pkt[19] = 0x00 // 0x00100002
        pkt[20] = 0 // slot 0
        pkt[21] = 2 // connected
        pkt[22] = 2 // full gyro
        pkt[23] = 2 // bluetooth
        pkt[30] = 0x05 // full battery
        pkt[31] = 1 // active
        pkt[32] = 42 // packet number 42
        pkt[36] = 0x18 // D-Pad Up (0x10) + Options/Plus (0x08)
        pkt[37] = 0x20 // East / A (0x20)
        pkt[40] = 128; pkt[41] = 255 // left stick (0, +1)
        pkt[42] = 128; pkt[43] = 128 // right stick (0, 0)
        // Accel Z = -1.0f (-1.0 in IEEE 754 LE: 0x00, 0x00, 0x80, 0xBF) at offset 84
        pkt[84] = 0x00; pkt[85] = 0x00; pkt[86] = 0x80; pkt[87] = 0xBF
        // Gyro Pitch = 90.0f (0x00, 0x00, 0xB4, 0x42) at offset 88
        pkt[88] = 0x00; pkt[89] = 0x00; pkt[90] = 0xB4; pkt[91] = 0x42

        let crc = pkt.withUnsafeBytes { DsuShellClient.crc32($0, skipRange: 8..<12) }
        pkt[8] = UInt8(crc & 0xFF)
        pkt[9] = UInt8((crc >> 8) & 0xFF)
        pkt[10] = UInt8((crc >> 16) & 0xFF)
        pkt[11] = UInt8((crc >> 24) & 0xFF)

        let parsed = DsuShellClient.parseDataPacket(Data(pkt))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.slot, 0)
        XCTAssertEqual(parsed?.connected, true)
        XCTAssertEqual(parsed?.packetNumber, 42)
        XCTAssertTrue(parsed?.padState.buttons.contains(.a) == true)
        XCTAssertTrue(parsed?.padState.buttons.contains(.menu) == true)
        XCTAssertEqual(parsed?.padState.y, 1.0)
        XCTAssertEqual(parsed?.accelG.2 ?? 0, -1.0, accuracy: 1e-5)
        XCTAssertEqual(parsed?.gyroDps.0 ?? 0, 90.0, accuracy: 1e-5)
        XCTAssertEqual(DsuShellClient.batteryInfo(for: 0x05).percent, 100)
    }
}
