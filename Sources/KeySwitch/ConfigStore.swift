import Foundation

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet { save() }
    }

    private let key = "com.keyswitch.config"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            config = .default
        }
    }

    func save() {
        config.keyboardAddress = BluetoothAddress.normalize(config.keyboardAddress)
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    var isConfigured: Bool {
        !config.keyboardAddress.isEmpty &&
        !config.pairingToken.isEmpty &&
        (!config.peerAddress.isEmpty || !config.peerHostName.isEmpty)
    }
}