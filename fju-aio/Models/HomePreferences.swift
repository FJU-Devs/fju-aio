import SwiftUI

@Observable
final class HomePreferences {

    private static let storageKey = "homeModuleIDs"

    var selectedModuleIDs: [String] {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.selectedModuleIDs = ids
        } else {
            self.selectedModuleIDs = ModuleRegistry.defaultHomeModuleIDs
        }
    }

    var selectedModules: [AppModule] {
        selectedModuleIDs.compactMap { ModuleRegistry.module(for: $0) }
    }

    func isSelected(_ moduleID: String) -> Bool {
        selectedModuleIDs.contains(moduleID)
    }

    func toggle(_ moduleID: String) {
        if let index = selectedModuleIDs.firstIndex(of: moduleID) {
            selectedModuleIDs.remove(at: index)
        } else {
            selectedModuleIDs.append(moduleID)
        }
    }

    func resetToDefaults() {
        selectedModuleIDs = ModuleRegistry.defaultHomeModuleIDs
    }

    private func save() {
        if let data = try? JSONEncoder().encode(selectedModuleIDs) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
