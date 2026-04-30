import SwiftUI

// MARK: - FriendListView
// Entry is gated: user must have published their profile first.
// If not published, shows a prompt to go to MyProfileView.

struct FriendListView: View {
    @AppStorage("myProfile.isPublished") private var isPublished = false

    var body: some View {
        if isPublished {
            FriendListContent()
        } else {
            ProfileRequiredView()
        }
    }
}

// MARK: - Profile Required Prompt

private struct ProfileRequiredView: View {
    var body: some View {
        ContentUnavailableView {
            Label("尚未建立公開資料", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("必須先發布你的公開資料，才能新增好友或被好友找到。")
        } actions: {
            NavigationLink(destination: MyProfileView()) {
                Text("前往建立資料")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("好友")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Friend List Content (shown when profile is published)

private struct FriendListContent: View {
    @State private var friendStore = FriendStore.shared
    @State private var showScanner = false
    @State private var showAddGroup = false
    @State private var scanError: String?
    @State private var lastScannedInfo: String?

    var body: some View {
        List {
            // MARK: Friends
            Section {
                if friendStore.friends.isEmpty {
                    ContentUnavailableView(
                        "尚無好友",
                        systemImage: "person.2.slash",
                        description: Text("點右上角掃描對方的個人 QR Code 來新增好友")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(friendStore.friends) { friend in
                        NavigationLink(value: friend) {
                            FriendRow(friend: friend)
                        }
                    }
                    .onDelete { offsets in
                        offsets.forEach { friendStore.removeFriend(id: friendStore.friends[$0].id) }
                    }
                }
            } header: {
                Text("好友")
            }

            // MARK: Groups
            Section {
                if !friendStore.groups.isEmpty {
                    ForEach(friendStore.groups) { group in
                        NavigationLink(value: group) {
                            GroupRow(group: group)
                        }
                    }
                    .onDelete { offsets in
                        offsets.forEach { friendStore.deleteGroup(id: friendStore.groups[$0].id) }
                    }
                }

                Button {
                    showAddGroup = true
                } label: {
                    Label("建立群組", systemImage: "plus.circle")
                }
                .disabled(friendStore.friends.isEmpty)
            } header: {
                Text("點名群組")
            } footer: {
                if friendStore.groups.isEmpty {
                    Text("建立群組後可以一鍵為所有成員點名。")
                }
            }
        }
        .navigationTitle("好友")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FriendRecord.self) { FriendDetailView(friend: $0) }
        .navigationDestination(for: FriendGroup.self) { GroupDetailView(group: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
            }
        }
        .alert("掃描結果", isPresented: Binding(
            get: { scanError != nil || lastScannedInfo != nil },
            set: { if !$0 { scanError = nil; lastScannedInfo = nil } }
        )) {
            Button("確定") { scanError = nil; lastScannedInfo = nil }
        } message: {
            Text(scanError ?? lastScannedInfo ?? "")
        }
        .sheet(isPresented: $showScanner) {
            AddFriendScannerSheet { qrString in
                showScanner = false
                handleScanned(qrString)
            }
        }
        .sheet(isPresented: $showAddGroup) {
            AddGroupSheet(store: friendStore)
        }
    }

    private func handleScanned(_ qrString: String) {
        switch ProfileQRService.parse(qrString: qrString) {
        case .profile(let payload):
            friendStore.addFriend(from: payload)
            lastScannedInfo = "已新增好友：\(payload.displayName)（\(payload.empNo)）"
            Task {
                if let profile = try? await CloudKitProfileService.shared.fetchProfile(recordName: payload.cloudKitRecordName) {
                    await MainActor.run {
                        friendStore.updateCachedProfile(profile, for: payload.cloudKitRecordName)
                    }
                }
            }
        case .groupRollcall:
            scanError = "這是點名 QR Code，請在「群組點名」頁面掃描。"
        case .unknown:
            scanError = "無法識別此 QR Code。"
        }
    }
}

// MARK: - Friend Row

struct FriendRow: View {
    let friend: FriendRecord

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(AppTheme.accent.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(String(friend.displayName.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(AppTheme.accent)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName).font(.body)
                Text(friend.empNo).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Group Row

private struct GroupRow: View {
    let group: FriendGroup

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.orange.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "person.3.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.body)
                Text("\(group.memberIds.count) 位成員").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add Friend Scanner Sheet

private struct AddFriendScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView(onScan: onScan).ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("掃描朋友的個人 QR Code")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 48)
                }
            }
            .navigationTitle("掃描 QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
    }
}

// MARK: - Add Group Sheet

private struct AddGroupSheet: View {
    let store: FriendStore
    @Environment(\.dismiss) private var dismiss

    @State private var groupName = ""
    @State private var selectedMemberIds: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section("群組名稱") {
                    TextField("例如：計算機概論", text: $groupName)
                }

                Section("選擇成員") {
                    ForEach(store.friends) { friend in
                        HStack {
                            FriendRow(friend: friend)
                            Spacer()
                            Image(systemName: selectedMemberIds.contains(friend.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedMemberIds.contains(friend.id)
                                                 ? AppTheme.accent : .secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedMemberIds.contains(friend.id) {
                                selectedMemberIds.remove(friend.id)
                            } else {
                                selectedMemberIds.insert(friend.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("建立群組")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("建立") {
                        store.createGroup(name: groupName, memberIds: Array(selectedMemberIds))
                        dismiss()
                    }
                    .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty || selectedMemberIds.isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        FriendListView()
    }
}
