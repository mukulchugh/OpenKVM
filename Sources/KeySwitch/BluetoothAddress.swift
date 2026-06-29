import Foundation

enum BluetoothAddress {
    /// IOBluetooth uses dashed lowercase MACs, e.g. `38-09-fb-28-24-f9`.
    static func normalize(_ raw: String) -> String {
        let hex = raw.lowercased().replacingOccurrences(of: ":", with: "-")
        let parts = hex.split(separator: "-").map(String.init)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 }) else { return raw.lowercased() }
        return parts.joined(separator: "-")
    }

    static func display(_ raw: String) -> String {
        normalize(raw).replacingOccurrences(of: "-", with: ":").uppercased()
    }
}