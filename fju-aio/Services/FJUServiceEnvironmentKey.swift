import SwiftUI

private struct FJUServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue: FJUServiceProtocol = FJUService.shared
}

extension EnvironmentValues {
    var fjuService: FJUServiceProtocol {
        get { self[FJUServiceEnvironmentKey.self] }
        set { self[FJUServiceEnvironmentKey.self] = newValue }
    }
}
