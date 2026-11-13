import SwiftUI
import UniformTypeIdentifiers

struct LeaveRequestView: View {
    @State private var selectedTab: Tab = .history

    enum Tab: String, CaseIterable {
        case history = "歷史假單"
        case stats = "請假統計"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("頁面", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch selectedTab {
                case .history: LeaveHistoryView()
                case .stats:   LeaveStatsView()
                }
            }
        }
        .navigationTitle("請假申請")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    LeaveApplyWizard()
                        .navigationTitle("申請假單")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("申請假單")
            }
        }
    }
}

// MARK: - Semester defaults

enum LeaveSemesterDefaults {
    /// Current (ROC year, term), preferring the school's semester list when cached.
    static func current() -> (year: Int, term: Int) {
        CurrentSemester.parse(CurrentSemester.code()) ?? CurrentSemester.estimated()
    }

    /// The academic year matching the current semester, or the newest one available.
    static func defaultYear(in years: [HyRecord]) -> HyRecord? {
        let year = current().year
        return years.first { $0.hy == year } ?? years.first
    }
}

// MARK: - Shared load-error row

private struct LeaveLoadErrorRow: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("載入失敗", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重試", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - History Tab

private struct LeaveHistoryView: View {
    private let leaveService = LeaveService.shared
    @State private var academicYears: [HyRecord] = []
    @State private var selectedHy: HyRecord?
    @State private var selectedHt: Int = CurrentSemester.estimated().term
    @State private var records: [LeaveRecord] = []
    @State private var isLoadingYears = true
    @State private var yearsError: String?
    @State private var isLoadingRecords = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    /// "hy-ht" of the most recent records request; used to skip duplicate loads.
    @State private var requestedKey: String?
    /// Bumped on every request so stale responses are dropped.
    @State private var loadGeneration = 0

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var selectionKey: String? {
        selectedHy.map { "\($0.hy)-\(selectedHt)" }
    }

    var body: some View {
        content
            .task {
                // Re-appearing (e.g. back from a detail page): refresh quietly, keep the selection.
                if hasLoaded {
                    await loadRecords()
                } else {
                    await loadInitial()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if academicYears.isEmpty && isLoadingYears {
            ProgressView("載入中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if academicYears.isEmpty {
            ContentUnavailableView {
                Label("載入失敗", systemImage: "exclamationmark.triangle")
            } description: {
                Text(yearsError ?? "無法取得學年度資料")
            } actions: {
                Button("重試") { Task { await loadInitial() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    Picker("學年度", selection: $selectedHy) {
                        ForEach(academicYears) { hy in
                            Text(hy.hyNa).tag(Optional(hy))
                        }
                    }
                    Picker("學期", selection: $selectedHt) {
                        Text("第 1 學期").tag(1)
                        Text("第 2 學期").tag(2)
                    }
                }

                if let error = errorMessage {
                    Section {
                        LeaveLoadErrorRow(message: error) {
                            Task { await loadRecords() }
                        }
                    }
                } else if isLoadingRecords && records.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("載入中…").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section(records.isEmpty ? "尚無記錄" : "\(records.count) 筆記錄") {
                        if records.isEmpty {
                            Text("尚無請假紀錄").foregroundStyle(.secondary)
                        } else {
                            ForEach(records, id: \.id) { record in
                                LeaveRecordRow(
                                    record: record,
                                    dateFormatter: dateFormatter,
                                    onRevoked: {
                                        // After a successful revoke, reload the list
                                        Task { await loadRecords() }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loadRecords() }
            .onChange(of: selectionKey) { _, newKey in
                guard hasLoaded, newKey != requestedKey else { return }
                records = []
                Task { await loadRecords() }
            }
        }
    }

    private func loadInitial() async {
        isLoadingYears = true
        yearsError = nil
        do {
            let years = try await leaveService.fetchAcademicYears()
            academicYears = years
            selectedHy = LeaveSemesterDefaults.defaultYear(in: years)
            selectedHt = LeaveSemesterDefaults.current().term
        } catch is CancellationError {
            isLoadingYears = false
            return
        } catch {
            yearsError = error.localizedDescription
            isLoadingYears = false
            return
        }
        isLoadingYears = false
        hasLoaded = true
        await loadRecords()
    }

    private func loadRecords() async {
        guard let hy = selectedHy else { return }
        let ht = selectedHt
        requestedKey = "\(hy.hy)-\(ht)"
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingRecords = true
        errorMessage = nil
        do {
            let fetched = try await leaveService.fetchLeaveRecords(academicYear: hy.hy, semester: ht)
            guard generation == loadGeneration else { return }
            records = fetched
        } catch is CancellationError {
            // Silently ignore task cancellation (e.g. pull-to-refresh interrupted).
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
        if generation == loadGeneration { isLoadingRecords = false }
    }
}

// MARK: - Leave Record Row

private struct LeaveRecordRow: View {
    let record: LeaveRecord
    let dateFormatter: DateFormatter
    let onRevoked: () -> Void

    private var beginDate: Date? { dateFormatter.date(from: record.beginDate) }
    private var endDate: Date? { dateFormatter.date(from: record.endDate) }

    private var displayDateRange: String {
        let df = DateFormatter()
        df.dateFormat = "M/d"
        guard let s = beginDate, let e = endDate else { return record.beginDate }
        let start = df.string(from: s)
        let end = df.string(from: e)
        return start == end ? start : "\(start) – \(end)"
    }

    private var statusColor: Color {
        let name = record.applyStatusNa
        if name.contains("通過") || name.contains("核准") { return .green }
        if name.contains("撤銷") || name.contains("駁回") || name.contains("拒絕") { return .secondary }
        return .orange
    }

    var body: some View {
        NavigationLink {
            LeaveDetailView(record: record, onRevoked: onRevoked)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // ── Title row ──
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.leaveNa)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("#\(record.applyNo)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(record.applyStatusNa)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(statusColor)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                // ── Meta chips ──
                HStack(spacing: 12) {
                    Label(displayDateRange, systemImage: "calendar")
                    Label("\(record.beginSectNa)–\(record.endSectNa)", systemImage: "clock")
                    Label("\(record.totalDay)天\(record.totalSect)節", systemImage: "square.stack")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // ── Reason ──
                if !record.leaveReason.isEmpty {
                    Text(record.leaveReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Leave Detail Page

private struct LeaveDetailView: View {
    let record: LeaveRecord
    let onRevoked: () -> Void

    @State private var approvalResults: [LeaveApplyResult] = []
    @State private var isLoadingFlow = true
    @State private var isPDFLoading = false
    @State private var pdfData: Data?
    @State private var showPDFPreview = false
    @State private var pdfError: String?
    @State private var showRevokeSheet = false
    /// Set after a successful revoke so the page stops offering the action before it pops.
    @State private var didRevoke = false
    @Environment(\.dismiss) private var dismiss

    private var displayedStatus: String {
        didRevoke ? "已撤銷" : record.applyStatusNa
    }

    private let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func formatDate(_ raw: String) -> String {
        guard let d = isoFormatter.date(from: raw) else { return raw }
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d (EEE)"
        f.locale = Locale(identifier: "zh_TW")
        return f.string(from: d)
    }

    private var statusColor: Color {
        let name = displayedStatus
        if name.contains("通過") || name.contains("核准") { return .green }
        if name.contains("撤銷") || name.contains("駁回") || name.contains("拒絕") { return .secondary }
        return .orange
    }

    private var canRevoke: Bool {
        let name = displayedStatus
        return !didRevoke && !name.contains("撤銷") && !name.contains("通過") && !name.contains("核准")
    }

    var body: some View {
        List {
            // ── Header card ──
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.leaveNa)
                                .font(.title3.weight(.bold))
                            Text(record.leaveKindNa)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(displayedStatus)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(statusColor)
                            .background(statusColor.opacity(0.12), in: Capsule())
                    }

                    Divider()

                    HStack(spacing: 0) {
                        summaryCell(label: "開始", value: formatDate(record.beginDate))
                        Divider().frame(height: 36)
                        summaryCell(label: "結束", value: formatDate(record.endDate))
                        Divider().frame(height: 36)
                        summaryCell(label: "節次", value: "\(record.beginSectNa)–\(record.endSectNa)")
                        Divider().frame(height: 36)
                        summaryCell(label: "合計", value: "\(record.totalDay)天\(record.totalSect)節")
                    }
                }
                .padding(.vertical, 4)
            }

            // ── Details ──
            Section("基本資訊") {
                detailRow(label: "假單編號", value: "#\(record.applyNo)")
                detailRow(label: "學生姓名", value: record.stuCna)
            }

            Section("請假事由") {
                Text(record.leaveReason.isEmpty ? "（無）" : record.leaveReason)
                    .foregroundStyle(record.leaveReason.isEmpty ? .secondary : .primary)
            }

            // ── Approval flow ──
            Section("簽核流程") {
                if isLoadingFlow {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("載入中…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if approvalResults.isEmpty {
                    Text("無簽核資料").foregroundStyle(.secondary)
                } else {
                    ForEach(approvalResults) { item in
                        ApprovalResultRow(item: item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("假單詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    // 列印假單
                    Button {
                        guard !isPDFLoading else { return }
                        Task { await downloadPDF() }
                    } label: {
                        if isPDFLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "printer")
                        }
                    }
                    .disabled(isPDFLoading)
                    .accessibilityLabel(isPDFLoading ? "列印假單，下載中" : "列印假單")

                    // 撤銷假單
                    if canRevoke {
                        Button(role: .destructive) {
                            showRevokeSheet = true
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .tint(.red)
                        .accessibilityLabel("撤銷假單")
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showPDFPreview) {
            if let data = pdfData {
                PDFPageView(pdfData: data, title: "假單 \(record.applyNo)")
            }
        }
        .sheet(isPresented: $showRevokeSheet, onDismiss: {
            // The record is immutable here; pop back so the refreshed list shows the new status.
            if didRevoke { dismiss() }
        }) {
            RevokeLeaveSheet(record: record) {
                didRevoke = true
                onRevoked()
            }
        }
        .alert("下載失敗", isPresented: Binding(
            get: { pdfError != nil },
            set: { if !$0 { pdfError = nil } }
        )) {
            Button("確定", role: .cancel) { pdfError = nil }
        } message: {
            Text(pdfError ?? "")
        }
        .task { await loadFlow() }
    }

    @ViewBuilder
    private func summaryCell(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func loadFlow() async {
        isLoadingFlow = true
        approvalResults = (try? await LeaveService.shared.fetchApprovalFlow(leaveApplySn: record.leaveApplySn)) ?? []
        isLoadingFlow = false
    }

    private func downloadPDF() async {
        isPDFLoading = true
        pdfError = nil
        do {
            pdfData = try await LeaveService.shared.downloadLeaveFormPDF(leaveApplySn: record.leaveApplySn)
            showPDFPreview = true
        } catch {
            pdfError = error.localizedDescription
        }
        isPDFLoading = false
    }
}


private struct ApprovalResultRow: View {
    let item: LeaveApplyResult

    private var statusColor: Color {
        switch item.applyStatus {
        case 9: return .green   // 通過
        case 5: return .orange  // 待審核
        case 3: return .red     // 拒絕
        default: return .secondary
        }
    }

    private var auditTimeDisplay: String? {
        guard let t = item.auditTime, !t.isEmpty else { return nil }
        // Convert ISO string to readable format
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        if let d = f.date(from: t) {
            let out = DateFormatter()
            out.dateFormat = "yyyy/M/d HH:mm"
            return out.string(from: d)
        }
        return String(t.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.couCna)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(item.applyStatusNa)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(statusColor)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            if let tch = item.tchCna {
                Text("授課教師：\(tch)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let seqTims = item.seqTims, !seqTims.isEmpty {
                Text("節次：\(seqTims.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let opinion = item.auditOpinion, !opinion.isEmpty {
                Text("簽核意見：\(opinion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let timeStr = auditTimeDisplay {
                Text("簽核時間：\(timeStr)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - PDF Page View (pushed via NavigationLink)

import PDFKit

private struct PDFPageView: View {
    let pdfData: Data
    let title: String

    var body: some View {
        PDFPreviewView(data: pdfData)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: pdfFileURL(pdfData, name: title)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享")
                }
            }
    }

    private func pdfFileURL(_ data: Data, name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).pdf")
        try? data.write(to: url)
        return url
    }
}

// MARK: - Revoke Leave Sheet (two-step confirmation)

private struct RevokeLeaveSheet: View {
    let record: LeaveRecord
    let onRevoked: () -> Void

    @State private var cancelMemo: String = ""
    @State private var showConfirmAlert = false
    @State private var isRevoking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isMemoFocused: Bool

    private var canSubmit: Bool {
        !cancelMemo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("假單資訊") {
                    HStack {
                        Text("假單編號").foregroundStyle(.secondary)
                        Spacer()
                        Text(record.applyNo)
                    }
                    HStack {
                        Text("假別").foregroundStyle(.secondary)
                        Spacer()
                        Text(record.leaveNa)
                    }
                    HStack {
                        Text("狀態").foregroundStyle(.secondary)
                        Spacer()
                        Text(record.applyStatusNa)
                    }
                    if !record.leaveReason.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("請假事由").foregroundStyle(.secondary).font(.caption)
                            Text(record.leaveReason)
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("撤銷說明")
                            .font(.subheadline)
                        TextEditor(text: $cancelMemo)
                            .frame(minHeight: 100)
                            .focused($isMemoFocused)
                            .overlay(
                                Group {
                                    if cancelMemo.isEmpty {
                                        Text("請輸入撤銷說明（必填）")
                                            .foregroundStyle(.tertiary)
                                            .allowsHitTesting(false)
                                            .padding(.top, 8)
                                            .padding(.leading, 4)
                                    }
                                },
                                alignment: .topLeading
                            )
                        Text("\(cancelMemo.count)/500")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("撤銷說明")
                } footer: {
                    Text("撤銷後不可復原，請確認後再送出。")
                        .foregroundStyle(.orange)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("撤銷假單")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(isRevoking)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("確定") {
                        showConfirmAlert = true
                    }
                    .disabled(!canSubmit || isRevoking)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isMemoFocused = false }
                }
            }
            .overlay {
                if isRevoking {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                    ProgressView("撤銷中…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .interactiveDismissDisabled(isRevoking)
            // Second-level confirmation alert
            .alert("確定要撤銷嗎？", isPresented: $showConfirmAlert) {
                Button("確定", role: .destructive) {
                    Task { await revokeLeave() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("再次提醒：確認撤銷後不可復原喔！")
            }
        }
        .onChange(of: cancelMemo) { _, new in
            if new.count > 500 {
                cancelMemo = String(new.prefix(500))
            }
        }
    }

    private func revokeLeave() async {
        isRevoking = true
        errorMessage = nil
        do {
            try await LeaveService.shared.revokeLeave(leaveApplySn: record.leaveApplySn, cancelMemo: cancelMemo)
            onRevoked()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isRevoking = false
    }
}

// MARK: - Stats Tab

private struct LeaveStatsView: View {
    private let leaveService = LeaveService.shared

    @State private var academicYears: [HyRecord] = []
    @State private var selectedHy: HyRecord?
    @State private var selectedHt: Int = CurrentSemester.estimated().term
    @State private var statSummary: LeaveStatSummary?
    @State private var isLoadingYears = true
    @State private var yearsError: String?
    @State private var isLoadingStats = false
    @State private var errorMessage: String?
    @State private var deadline: String?
    @State private var hasLoaded = false
    /// "hy-ht" of the most recent stats request; used to skip duplicate loads.
    @State private var requestedKey: String?
    /// Bumped on every request so stale responses are dropped.
    @State private var loadGeneration = 0

    private var stats: [LeaveStatRecord] {
        statSummary?.statLeaveCouList ?? []
    }

    private var selectionKey: String? {
        selectedHy.map { "\($0.hy)-\(selectedHt)" }
    }

    var body: some View {
        Group {
            if academicYears.isEmpty && isLoadingYears {
                ProgressView("載入中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if academicYears.isEmpty {
                ContentUnavailableView {
                    Label("載入失敗", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(yearsError ?? "無法取得學年度資料")
                } actions: {
                    Button("重試") { Task { await loadInitial() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Picker("學年度", selection: $selectedHy) {
                            ForEach(academicYears) { hy in
                                Text(hy.hyNa).tag(Optional(hy))
                            }
                        }
                        Picker("學期", selection: $selectedHt) {
                            Text("第 1 學期").tag(1)
                            Text("第 2 學期").tag(2)
                        }
                    }

                    if let error = errorMessage {
                        Section {
                            LeaveLoadErrorRow(message: error) {
                                Task { await loadStats() }
                            }
                        }
                    } else if isLoadingStats && statSummary == nil {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("載入中…").foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let deadline {
                        Section("請假申請截止日") {
                            Text(deadline).foregroundStyle(.secondary)
                        }
                    }

                    if let statSummary {
                        Section("請假統計") {
                            HStack {
                                Text("總請假節次")
                                Spacer()
                                Text("\(statSummary.sumLeaveSect) 節")
                                    .font(.body.weight(.semibold))
                            }
                            HStack {
                                Text("已核准")
                                Spacer()
                                Text("\(statSummary.sumLeaveSectYes) 節")
                                    .foregroundStyle(.green)
                            }
                            HStack {
                                Text("未核准")
                                Spacer()
                                Text("\(statSummary.sumLeaveSectNo) 節")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    if statSummary?.sumLeaveSect == 0 {
                        Section("請假統計") {
                            Text("尚無請假紀錄").foregroundStyle(.secondary)
                        }
                    } else if !stats.isEmpty {
                        Section("課程明細") {
                            ForEach(stats) { stat in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(stat.couCna)
                                                .font(.body.weight(.medium))
                                            HStack(spacing: 6) {
                                                if !stat.courseCode.isEmpty {
                                                    Text(stat.courseCode)
                                                }
                                                if let tchCna = stat.tchCna, !tchCna.isEmpty {
                                                    Text(tchCna)
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text("\(stat.cntLeaveSect) / \(stat.sumSect) 節")
                                                .font(.body.weight(.semibold))
                                            if stat.cntLeaveSectNo > 0 {
                                                Text("未核准 \(stat.cntLeaveSectNo)")
                                                    .font(.caption)
                                                    .foregroundStyle(.orange)
                                            } else if stat.cntLeaveSectYes > 0 {
                                                Text("已核准 \(stat.cntLeaveSectYes)")
                                                    .font(.caption)
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                    }

                                    if !stat.leaveSeqTims.isEmpty {
                                        ForEach(stat.leaveSeqTims) { tim in
                                            HStack(spacing: 6) {
                                                Image(systemName: "calendar")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Text([tim.displayDate, tim.section].compactMap { $0 }.joined(separator: " "))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    } else if !stat.seqTims.isEmpty {
                                        Text(stat.seqTims.map(\.displayText).joined(separator: "、"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await loadStats() }
                .onChange(of: selectionKey) { _, newKey in
                    guard newKey != requestedKey else { return }
                    statSummary = nil
                    Task { await loadStats() }
                }
            }
        }
        .task {
            // Re-appearing: refresh quietly and keep the user's selection.
            if hasLoaded {
                await loadStats()
            } else {
                await loadInitial()
            }
        }
    }

    private func loadInitial() async {
        isLoadingYears = true
        yearsError = nil
        async let hyTask      = leaveService.fetchAcademicYears()
        async let deadlineTask = leaveService.fetchApplyDeadline()
        do {
            let years = try await hyTask
            academicYears = years
            selectedHy = LeaveSemesterDefaults.defaultYear(in: years)
            selectedHt = LeaveSemesterDefaults.current().term
        } catch is CancellationError {
            isLoadingYears = false
            return
        } catch {
            yearsError = error.localizedDescription
            isLoadingYears = false
            return
        }
        isLoadingStats = true
        isLoadingYears = false
        deadline = (try? await deadlineTask) ?? nil
        hasLoaded = true
        await loadStats()
    }

    private func loadStats() async {
        guard let hy = selectedHy else { return }
        let ht = selectedHt
        requestedKey = "\(hy.hy)-\(ht)"
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingStats = true
        errorMessage = nil
        do {
            let fetched = try await leaveService.fetchLeaveStat(academicYear: hy.hy, semester: ht)
            guard generation == loadGeneration else { return }
            statSummary = fetched
        } catch is CancellationError {
            // Silently ignore task cancellation (e.g. pull-to-refresh interrupted).
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
        if generation == loadGeneration { isLoadingStats = false }
    }
}
