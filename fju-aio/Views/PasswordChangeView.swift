import SwiftUI

/// Lets the user update the stored LDAP password in place — e.g. after the school's
/// semester password change causes an "invalid credentials" error — without a full
/// sign-out, which would wipe local data.
struct PasswordChangeView: View {
    @Environment(AuthenticationManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 56))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.top, 32)

                        Text("需要更新密碼")
                            .font(.title2.bold())

                        Text("學校密碼可能已變更，請輸入新密碼以繼續使用。這不會清除你在裝置上的資料。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: 12) {
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(authManager.storedUsername ?? "")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)

                            Divider()
                                .padding(.leading, 52)

                            HStack {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                SecureField("新密碼", text: $newPassword)
                                    .textContentType(.password)
                                    .submitLabel(.go)
                                    .onSubmit {
                                        guard !newPassword.isEmpty else { return }
                                        Task { await performUpdate() }
                                    }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))

                        if let errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                        }

                        Button {
                            Task { await performUpdate() }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                                    .fill(isButtonDisabled ? AppTheme.accent.opacity(0.35) : AppTheme.accent)

                                if isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("更新密碼")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                        }
                        .buttonStyle(.plain)
                        .disabled(isButtonDisabled)
                        .animation(.easeInOut(duration: 0.15), value: isButtonDisabled)
                    }
                    .padding(.horizontal, 24)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("更新密碼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍後再說") { dismiss() }
                }
            }
        }
    }

    private var isButtonDisabled: Bool {
        isLoading || newPassword.isEmpty
    }

    private func performUpdate() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await authManager.updatePassword(newPassword)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    PasswordChangeView()
        .environment(AuthenticationManager())
}
