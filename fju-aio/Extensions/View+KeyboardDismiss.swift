import SwiftUI
import UIKit

extension View {
    /// Dismisses the keyboard when the user taps outside of any focused text input.
    /// Interactive controls (buttons, links, text fields) still receive their own taps first,
    /// so this only fires on genuinely empty space.
    func dismissKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}
