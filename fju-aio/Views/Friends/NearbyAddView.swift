import SwiftUI

// MARK: - NearbyAddView
// Both devices advertise their profile via BLE and scan for each other.
// Tapping "加好友" adds locally and writes an add request to the peer, so the
// other side can confirm adding back.

struct NearbyAddView: View {
    let session: SISSession?
    /// Called when the user confirms adding a peer.
    let onAddPeer: (NearbyPeerProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nearbyService = NearbyFriendService.shared
    @State private var addedIds: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                // MARK: Status header
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(nearbyService.isActive ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: nearbyService.isActive
                                  ? "antenna.radiowaves.left.and.right"
                                  : "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(nearbyService.isActive ? .green : .secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(nearbyService.isActive ? "正在搜尋附近的朋友" : "未啟動")
                                .font(.body.weight(.medium))
                            Text("雙方都需要開啟此畫面")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if nearbyService.isActive {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: Discovered peers (profile already read — ready to add)
                let pending = nearbyService.discoveredPeers.filter { !addedIds.contains($0.id) }
                let added   = nearbyService.discoveredPeers.filter {  addedIds.contains($0.id) }

                if !nearbyService.incomingAddRequests.isEmpty {
                    Section("邀請") {
                        ForEach(nearbyService.incomingAddRequests) { peer in
                            incomingRequestRow(peer)
                        }
                    }
                }

                if !pending.isEmpty {
                    Section("附近的人") {
                        ForEach(pending) { peer in
                            peerRow(peer, isAdded: false)
                        }
                    }
                }

                if !added.isEmpty {
                    Section("已新增") {
                        ForEach(added) { peer in
                            peerRow(peer, isAdded: true)
                        }
                    }
                }

                if nearbyService.isActive && nearbyService.discoveredPeers.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "person.2.slash")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("附近尚未找到朋友\n請確認對方也開啟此畫面")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 16)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("附近加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") {
                        nearbyService.stop()
                        dismiss()
                    }
                }
            }
            .task(id: session?.empNo) {
                startNearby()
            }
            .onDisappear {
                nearbyService.stop()
            }
        }
    }

    // MARK: - Peer Row

    @ViewBuilder
    private func peerRow(_ peer: NearbyPeerProfile, isAdded: Bool) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(AppTheme.accent.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(String(peer.displayName.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(AppTheme.accent)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName).font(.body)
                Text(peer.empNo).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if isAdded {
                Label("已新增", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button("加好友") {
                    addedIds.insert(peer.id)
                    onAddPeer(peer)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func startNearby() {
        guard let session else { return }
        let payload = ProfileQRService.makeMutualPayload(
            userId: session.userId,
            empNo: session.empNo,
            displayName: session.userName
        )
        nearbyService.start(profile: payload)
    }

    private func incomingRequestRow(_ peer: NearbyPeerProfile) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(.green)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(peer.displayName) 已加你為好友")
                    .font(.body)
                Text("要加回對方嗎？")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("加好友") {
                addedIds.insert(peer.id)
                onAddPeer(peer)
                nearbyService.dismissIncomingRequest(id: peer.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
