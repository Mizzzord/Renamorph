import Foundation

public enum AppDataDirectory {
    public static func resolve(in support: URL) -> URL {
        let current = support.appendingPathComponent("Renamorph", isDirectory: true)
        let legacy = support.appendingPathComponent("ConsulMAC", isDirectory: true)
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.appendingPathComponent("state.json").path) {
            return legacy
        }
        return current
    }
}
