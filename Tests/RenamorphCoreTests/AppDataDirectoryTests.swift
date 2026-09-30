import Foundation
import Testing
@testable import RenamorphCore

@Test func renamedApplicationKeepsLegacyOriginalsAndState() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: support) }
    let current = support.appendingPathComponent("Renamorph")
    let legacy = support.appendingPathComponent("ConsulMAC")
    #expect(AppDataDirectory.resolve(in: support).path == current.path)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let bytes = Data("saved history".utf8)
    try bytes.write(to: legacy.appendingPathComponent("state.json"))
    #expect(AppDataDirectory.resolve(in: support).path == legacy.path)
    #expect(try Data(contentsOf: legacy.appendingPathComponent("state.json")) == bytes)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    #expect(AppDataDirectory.resolve(in: support).path == current.path)
    #expect(try Data(contentsOf: legacy.appendingPathComponent("state.json")) == bytes)
}
