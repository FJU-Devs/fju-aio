import SwiftUI

private struct FJUServiceKey: EnvironmentKey {
    static let defaultValue: any FJUServiceProtocol = MockFJUService()
}

extension EnvironmentValues {
    var fjuService: any FJUServiceProtocol {
        get { self[FJUServiceKey.self] }
        set { self[FJUServiceKey.self] = newValue }
    }
}
