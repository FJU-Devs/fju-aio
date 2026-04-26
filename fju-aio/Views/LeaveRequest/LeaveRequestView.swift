import SwiftUI
import UniformTypeIdentifiers

struct LeaveRequestView: View {
    @State private var selectedTab: Tab = .history

    enum Tab: String, CaseIterable {
        case history = "歷史假單"
        case apply = "申請請假"
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
                case .apply:   LeaveApplyView()
                case .stats:   LeaveStatsView()
                }
            }
        }
        .navigationTitle("請假申請")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - History Tab

private struct LeaveHistoryView: View {
    private let leaveService = LeaveService.shared
    @State private var academicYears: [HyRecord] = []
    @State private var selectedHy: HyRecord?
    @State private var selectedHt: Int = 2
    @State private var records: [LeaveRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var recordToCancel: LeaveRecord?
    @State private var isCancelling = false
    @State private var cancelErrorMessage: String?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        content
            .task { await loadInitial() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("載入中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            ContentUnavailableView(
                "載入失敗",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
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
                .onChange(of: selectedHy) { _, _ in Task { await loadRecords() } }
                .onChange(of: selectedHt) { _, _ in Task { await loadRecords() } }

                Section(records.isEmpty ? "尚無記錄" : "\(records.count) 筆記錄") {
                    if records.isEmpty {
                        Text("尚無請假紀錄").foregroundStyle(.secondary)
                    } else {
                        ForEach(records, id: \.id) { record in
                            LeaveRecordRow(record: record, dateFormatter: dateFormatter) {
                                recordToCancel = record
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loadRecords() }
        }
    }

    // placeholder to attach modifiers below
    private var alertModifiers: some View { EmptyView() }

    // keep the alert modifiers on the outer body — re-attach via wrapper below
    // Actually we'll attach them inline:
    private var bodyWithAlerts: some View {
        content
            .task { await loadInitial() }
        .alert("確認取消假單", isPresented: Binding(
            get: { recordToCancel != nil },
            set: { if !$0 { recordToCancel = nil } }
        )) {
            Button("取消假單", role: .destructive) {
                if let record = recordToCancel {
                    Task { await cancelRecord(record) }
                }
            }
            Button("返回", role: .cancel) { recordToCancel = nil }
        } message: {
            if let record = recordToCancel {
                Text("確定要取消 \(record.leaveNa) 假單（\(record.applyNo)）嗎？")
            }
        }
        .alert("取消失敗", isPresented: Binding(
            get: { cancelErrorMessage != nil },
            set: { if !$0 { cancelErrorMessage = nil } }
        )) {
            Button("確定", role: .cancel) { cancelErrorMessage = nil }
        } message: {
            Text(cancelErrorMessage ?? "")
        }
    }

    private func loadInitial() async {
        isLoading = true
        errorMessage = nil
        do {
            academicYears = try await leaveService.fetchAcademicYears()
            selectedHy = academicYears.first
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return
        }
        await loadRecords()
    }

    private func loadRecords() async {
        guard let hy = selectedHy else { return }
        isLoading = true
        errorMessage = nil
        do {
            records = try await leaveService.fetchLeaveRecords(academicYear: hy.hy, semester: selectedHt)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func cancelRecord(_ record: LeaveRecord) async {
        isCancelling = true
        do {
            try await leaveService.cancelLeave(leaveApplySn: record.leaveApplySn)
            records.removeAll { $0.leaveApplySn == record.leaveApplySn }
        } catch {
            cancelErrorMessage = error.localizedDescription
        }
        isCancelling = false
        recordToCancel = nil
    }
}

private struct LeaveRecordRow: View {
    let record: LeaveRecord
    let dateFormatter: DateFormatter
    let onCancel: () -> Void

    private var beginDate: Date? { dateFormatter.date(from: record.beginDate) }
    private var endDate: Date? { dateFormatter.date(from: record.endDate) }

    private var displayDateRange: String {
        let display = DateFormatter()
        display.dateFormat = "M/d"
        guard let s = beginDate, let e = endDate else { return record.beginDate }
        let start = display.string(from: s)
        let end = display.string(from: e)
        return start == end ? start : "\(start)–\(end)"
    }

    private var statusColor: Color {
        switch record.applyStatus {
        case 9: return .green
        case 5: return .red
        default: return .orange
        }
    }

    // Draft (0=編輯中) and pending (1=待審) records can be cancelled
    private var canCancel: Bool { record.applyStatus == 0 || record.applyStatus == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.leaveNa)
                        .font(.body.weight(.semibold))
                    Text("假單號：\(record.applyNo)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(record.applyStatusNa)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(statusColor)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            HStack(spacing: 16) {
                Label(displayDateRange, systemImage: "calendar")
                Label("\(record.beginSectNa)–\(record.endSectNa)", systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !record.leaveReason.isEmpty {
                Text(record.leaveReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text("共 \(record.totalDay) 天 \(record.totalSect) 節")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                if canCancel {
                    Button("取消假單", role: .destructive, action: onCancel)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Apply Tab

private struct LeaveApplyView: View {
    private let leaveService = LeaveService.shared

    // Reference data
    @State private var academicYears: [HyRecord] = []
    @State private var leaveKindCategories: [LeaveKind] = []  // 一般請假, 考試請假
    @State private var isLoading = true
    @State private var loadError: String?

    // Form fields — all exposed per API spec
    @State private var selectedHy: HyRecord?           // 學年度
    @State private var selectedHt: Int = 2             // 學期 1 or 2
    @State private var selectedCategory: LeaveKind?    // leaveKind (category)
    @State private var examKind: Int = 0               // 0=非考試
    @State private var beginDate = Date()
    @State private var endDate = Date()
    @State private var beginSectNo: Int = 1
    @State private var endSectNo: Int = 13
    @State private var reason = ""
    @State private var phoneNumber = ""
    @State private var emailAccount = ""
    @State private var proofFileItem: ProofFileItem?   // 佐證文件

    @State private var isSubmitting = false
    @State private var submitResult: SubmitResult?
    @State private var showDocPicker = false

    enum SubmitResult {
        case success(Int)
        case failure(String)
    }

    struct ProofFileItem {
        let data: Data
        let filename: String
        let ext: String
    }

    private let sectOptions = Array(1...13)
    private let htOptions = [1, 2]

    private var canSubmit: Bool {
        selectedHy != nil &&
        selectedCategory != nil &&
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isValidEmail(emailAccount) &&
        !isSubmitting
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("載入中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Text("載入失敗：\(error)")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重試") { Task { await loadReferenceData() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    // MARK: 學年度 / 學期
                    Section("學年度與學期") {
                        Picker("學年度", selection: $selectedHy) {
                            Text("請選擇").tag(Optional<HyRecord>.none)
                            ForEach(academicYears) { hy in
                                Text(hy.hyNa).tag(Optional(hy))
                            }
                        }
                        Picker("學期", selection: $selectedHt) {
                            Text("第 1 學期").tag(1)
                            Text("第 2 學期").tag(2)
                        }
                    }

                    // MARK: 假別 / 考試類別
                    Section("假別") {
                        Picker("請假性質", selection: $selectedCategory) {
                            Text("請選擇").tag(Optional<LeaveKind>.none)
                            ForEach(leaveKindCategories) { cat in
                                Text(cat.leaveNa).tag(Optional(cat))
                            }
                        }
                        .onChange(of: selectedCategory) { _, newVal in
                            // 考試請假 → examKind 預設 1，一般請假 → 0
                            examKind = (newVal?.value == 20) ? 1 : 0
                        }

                        if selectedCategory?.value == 20 {
                            Picker("考試類別", selection: $examKind) {
                                Text("期中考").tag(1)
                                Text("期末考").tag(2)
                                Text("補考").tag(3)
                                Text("其他考試").tag(9)
                            }
                        }
                    }

                    // MARK: 請假日期
                    Section("請假日期") {
                        DatePicker("開始日期", selection: $beginDate, displayedComponents: .date)
                            .onChange(of: beginDate) { _, v in
                                if endDate < v { endDate = v }
                            }
                        DatePicker("結束日期", selection: $endDate, in: beginDate..., displayedComponents: .date)
                    }

                    // MARK: 節次
                    Section("節次") {
                        Picker("開始節次", selection: $beginSectNo) {
                            ForEach(sectOptions, id: \.self) { n in
                                Text(sectionLabel(n)).tag(n)
                            }
                        }
                        Picker("結束節次", selection: $endSectNo) {
                            ForEach(sectOptions.filter { $0 >= beginSectNo }, id: \.self) { n in
                                Text(sectionLabel(n)).tag(n)
                            }
                        }
                        .onChange(of: beginSectNo) { _, v in
                            if endSectNo < v { endSectNo = v }
                        }
                    }

                    // MARK: 請假事由
                    Section("請假事由") {
                        TextField("請填寫請假原因（必填）", text: $reason, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    // MARK: 聯絡資料
                    Section("聯絡資料") {
                        LabeledContent("聯絡電話") {
                            TextField("必填", text: $phoneNumber)
                                .keyboardType(.phonePad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("電子郵件") {
                            TextField("必填", text: $emailAccount)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    // MARK: 佐證文件
                    Section("佐證文件") {
                        if let proof = proofFileItem {
                            HStack {
                                Label(proof.filename, systemImage: "doc.fill")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    proofFileItem = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        } else {
                            Button {
                                showDocPicker = true
                            } label: {
                                Label("選擇佐證文件（選填）", systemImage: "paperclip")
                            }
                        }
                    }

                    // MARK: 送出
                    Section {
                        Button {
                            Task { await submitLeave() }
                        } label: {
                            HStack {
                                Spacer()
                                if isSubmitting {
                                    ProgressView()
                                } else {
                                    Text("送出申請").bold()
                                }
                                Spacer()
                            }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .task { await loadReferenceData() }
        .fileImporter(
            isPresented: $showDocPicker,
            allowedContentTypes: [.pdf, .image, .jpeg, .png],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                proofFileItem = ProofFileItem(data: data, filename: url.lastPathComponent, ext: ext.isEmpty ? "pdf" : ext)
            }
        }
        .alert(alertTitle, isPresented: Binding(
            get: { submitResult != nil },
            set: { if !$0 { submitResult = nil } }
        )) {
            Button("確定", role: .cancel) { submitResult = nil }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ n: Int) -> String {
        // Map 1-13 to period labels (5=午休N, 6→D5, etc.)
        switch n {
        case 1...4: return "第 \(n) 節 (D\(n))"
        case 5:     return "午休 (DN)"
        default:    return "第 \(n-1) 節 (D\(n-1))"
        }
    }

    private var alertTitle: String {
        if case .success = submitResult { return "假單建立成功" }
        return "送出失敗"
    }

    private var alertMessage: String {
        switch submitResult {
        case .success(let sn): return "假單已建立，序號：\(sn)。\n請等待各級主管審核。"
        case .failure(let msg): return msg
        case nil: return ""
        }
    }

    private func loadReferenceData() async {
        isLoading = true
        loadError = nil

        async let hyTask    = leaveService.fetchAcademicYears()
        async let kindsTask = leaveService.fetchLeaveKinds()
        async let profileTask = SISService.shared.getStudentProfile()

        do {
            academicYears = try await hyTask
            selectedHy = academicYears.first
        } catch {
            loadError = error.localizedDescription
            isLoading = false
            return
        }

        do {
            leaveKindCategories = try await kindsTask
            selectedCategory = leaveKindCategories.first
        } catch {
            // Non-fatal — form can still be used if we know the values
        }

        if let profile = try? await profileTask {
            if phoneNumber.isEmpty { phoneNumber = profile.phone }
            if emailAccount.isEmpty { emailAccount = profile.email }
        }

        isLoading = false
    }

    private func isValidEmail(_ email: String) -> Bool {
        let t = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("@") && t.contains(".")
    }

    private func submitLeave() async {
        guard let hy = selectedHy, let category = selectedCategory else { return }
        isSubmitting = true

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        do {
            let leaveApplySn = try await leaveService.submitLeave(
                academicYear: hy.hy,
                semester: selectedHt,
                leaveKind: category.value,
                examKind: examKind,
                refLeaveSn: category.refLeaveSn,
                beginDate: df.string(from: beginDate),
                endDate: df.string(from: endDate),
                beginSectNo: beginSectNo,
                endSectNo: endSectNo,
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                phoneNumber: phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                emailAccount: emailAccount.trimmingCharacters(in: .whitespacesAndNewlines),
                proofFileData: proofFileItem?.data,
                proofFileExt: proofFileItem?.ext ?? "pdf"
            )
            reason = ""
            proofFileItem = nil
            submitResult = .success(leaveApplySn)
        } catch {
            submitResult = .failure(error.localizedDescription)
        }

        isSubmitting = false
    }
}

// MARK: - Stats Tab

private struct LeaveStatsView: View {
    private let leaveService = LeaveService.shared

    @State private var academicYears: [HyRecord] = []
    @State private var selectedHy: HyRecord?
    @State private var selectedHt: Int = 2
    @State private var stats: [LeaveStatRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var deadline: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("載入中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView(
                    "載入失敗",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
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
                    .onChange(of: selectedHy) { _, _ in Task { await loadStats() } }
                    .onChange(of: selectedHt) { _, _ in Task { await loadStats() } }

                    if let deadline {
                        Section("請假申請截止日") {
                            Text(deadline).foregroundStyle(.secondary)
                        }
                    }

                    if stats.isEmpty {
                        Section("請假統計") {
                            Text("尚無請假紀錄").foregroundStyle(.secondary)
                        }
                    } else {
                        Section("請假統計") {
                            ForEach(stats) { stat in
                                HStack {
                                    Text(stat.leaveNa)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(stat.totalDay) 天")
                                            .font(.body.weight(.medium))
                                        Text("\(stat.totalSect) 節")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        Section {
                            HStack {
                                Text("合計節次")
                                Spacer()
                                Text("\(stats.reduce(0) { $0 + $1.totalSect }) 節")
                                    .font(.body.weight(.semibold))
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await loadStats() }
            }
        }
        .task { await loadInitial() }
    }

    private func loadInitial() async {
        isLoading = true
        errorMessage = nil
        async let hyTask      = leaveService.fetchAcademicYears()
        async let deadlineTask = leaveService.fetchApplyDeadline()
        do {
            academicYears = try await hyTask
            selectedHy = academicYears.first
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return
        }
        deadline = try? await deadlineTask
        await loadStats()
    }

    private func loadStats() async {
        guard let hy = selectedHy else { return }
        isLoading = true
        errorMessage = nil
        do {
            stats = try await leaveService.fetchLeaveStat(academicYear: hy.hy, semester: selectedHt)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
