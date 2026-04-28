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
    @State private var recordToDelete: LeaveRecord?
    @State private var selectedRecord: LeaveRecord?
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        bodyWithAlerts
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
                                recordToDelete = record
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedRecord = record
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loadRecords() }
        }
    }

    private var bodyWithAlerts: some View {
        content
            .task { await loadInitial() }
        .alert("確認刪除假單", isPresented: Binding(
            get: { recordToDelete != nil },
            set: { if !$0 { recordToDelete = nil } }
        )) {
            Button("刪除假單", role: .destructive) {
                if let record = recordToDelete {
                    Task { await deleteRecord(record) }
                }
            }
            Button("返回", role: .cancel) { recordToDelete = nil }
        } message: {
            if let record = recordToDelete {
                Text("確定要刪除 \(record.leaveNa) 假單（\(record.applyNo)）嗎？")
            }
        }
        .alert("刪除失敗", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("確定", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .sheet(item: $selectedRecord) { record in
            NavigationStack {
                LeaveApplyView(
                    mode: record.applyStatus == 0 ? .edit(record.leaveApplySn) : .view(record.leaveApplySn)
                ) {
                    Task { await loadRecords() }
                }
            }
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

    private func deleteRecord(_ record: LeaveRecord) async {
        guard !isDeleting else { return }
        isDeleting = true
        do {
            try await leaveService.deleteLeave(leaveApplySn: record.leaveApplySn)
            await loadRecords()
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
        isDeleting = false
        recordToDelete = nil
    }
}

private struct LeaveRecordRow: View {
    let record: LeaveRecord
    let dateFormatter: DateFormatter
    let onDelete: () -> Void

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
        case 30: return .gray
        case 10: return .green
        case 9: return .green
        case 5: return .red
        default: return .orange
        }
    }

    private var canDelete: Bool { record.applyStatus == 0 }

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

                if canDelete {
                    Button("刪除假單", role: .destructive, action: onDelete)
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
    let mode: Mode
    let onSaved: (() -> Void)?

    enum Mode {
        case create
        case edit(Int)
        case view(Int)

        var leaveApplySn: Int? {
            switch self {
            case .create: return nil
            case .edit(let sn), .view(let sn): return sn
            }
        }

        var isReadOnly: Bool {
            if case .view = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .create: return "申請請假"
            case .edit: return "編輯假單"
            case .view: return "假單明細"
            }
        }
    }

    init(mode: Mode = .create, onSaved: (() -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
    }

    // Reference data
    @State private var academicYears: [HyRecord] = []
    @State private var leaveKindCategories: [LeaveKind] = []  // 一般請假, 考試請假
    @State private var examKinds: [LeaveKind] = []
    @State private var refLeaves: [RefLeave] = []
    @State private var sections: [LeaveSection] = []
    @State private var isLoading = true
    @State private var loadError: String?

    // Form fields — all exposed per API spec
    @State private var selectedHy: HyRecord?           // 學年度
    @State private var selectedHt: Int = 2             // 學期 1 or 2
    @State private var selectedCategory: LeaveKind?    // leaveKind (category)
    @State private var selectedExamKind: LeaveKind?    // RefExam
    @State private var selectedLeaveType: RefLeave?    // RefLeave
    @State private var beginDate = Date()
    @State private var endDate = Date()
    @State private var beginSectNo: Int = 1
    @State private var endSectNo: Int = 15
    @State private var reason = ""
    @State private var phoneNumber = ""
    @State private var emailAccount = ""
    @State private var proofFileItem: ProofFileItem?   // 佐證文件
    @State private var existingDocs: [LeaveApplyDoc] = []
    @State private var officialLeaveSn: Int = 0

    @State private var isSubmitting = false
    @State private var submitResult: SubmitResult?
    @State private var showDocPicker = false
    @State private var downloadingDocSn: Int?
    @State private var downloadedProofFile: DownloadedProofFile?

    enum SubmitResult {
        case success(Int)
        case failure(String)
    }

    struct ProofFileItem {
        let data: Data
        let filename: String
        let ext: String
        let mimeType: String
    }

    struct DownloadedProofFile: Identifiable {
        let id = UUID()
        let url: URL
        let filename: String
    }

    private let htOptions = [1, 2]

    private var canSubmit: Bool {
        guard !mode.isReadOnly else { return false }
        return selectedHy != nil &&
        selectedCategory != nil &&
        selectedLeaveType != nil &&
        (!isExamLeave || selectedExamKind != nil) &&
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isValidEmail(emailAccount) &&
        !isSubmitting
    }

    private var isExamLeave: Bool {
        selectedCategory?.value == 20
    }

    private var availableLeaveTypes: [RefLeave] {
        let leaves = refLeaves.filter { leave in
            if isExamLeave {
                guard let selectedExamKind else { return false }
                return selectedExamKind.value == 10 ? leave.isLeaveFlowQuiz : leave.isLeaveFlowExam
            }
            return leave.isLeaveFlow && leave.activeFlag == 1
        }

        return leaves.sorted {
            let lhsOrder = isExamLeave ? $0.examDisplayOrder : $0.displayOrder
            let rhsOrder = isExamLeave ? $1.examDisplayOrder : $1.displayOrder
            if lhsOrder == rhsOrder { return $0.refLeaveSn < $1.refLeaveSn }
            return lhsOrder < rhsOrder
        }
    }

    private var selectedDocMapping: LeaveDocMapping? {
        guard let selectedLeaveType else { return nil }
        let docs: [LeaveDocMapping]
        if isExamLeave {
            docs = selectedExamKind?.value == 10 ? selectedLeaveType.quizDocList : selectedLeaveType.examDocList
        } else {
            docs = selectedLeaveType.docList
        }
        return docs.first
    }

    private var leaveTypePickerOptions: [RefLeave] {
        var options = availableLeaveTypes
        if let selectedLeaveType, !options.contains(selectedLeaveType) {
            options.insert(selectedLeaveType, at: 0)
        }
        return options
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
                    .disabled(mode.isReadOnly)

                    // MARK: 假別 / 考試類別
                    Section("假別") {
                        Picker("請假性質", selection: $selectedCategory) {
                            Text("請選擇").tag(Optional<LeaveKind>.none)
                            ForEach(leaveKindCategories) { cat in
                                Text(cat.leaveNa).tag(Optional(cat))
                            }
                        }
                        .onChange(of: selectedCategory) { _, newVal in
                            selectedExamKind = (newVal?.value == 20) ? examKinds.first : nil
                            syncSelectedLeaveType()
                        }

                        if isExamLeave {
                            Picker("考試類別", selection: $selectedExamKind) {
                                Text("請選擇").tag(Optional<LeaveKind>.none)
                                ForEach(examKinds) { kind in
                                    Text(kind.leaveNa).tag(Optional(kind))
                                }
                            }
                            .onChange(of: selectedExamKind) { _, _ in syncSelectedLeaveType() }
                        }

                        Picker("請假類別", selection: $selectedLeaveType) {
                            Text("請選擇").tag(Optional<RefLeave>.none)
                            ForEach(leaveTypePickerOptions) { leave in
                                Text(leave.leaveNa).tag(Optional(leave))
                            }
                        }

                        if let doc = selectedDocMapping {
                            LabeledContent(doc.isRequired ? "必要證明" : "證明文件", value: doc.docCna)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(mode.isReadOnly)

                    // MARK: 請假日期
                    Section("請假日期") {
                        DatePicker("開始日期", selection: $beginDate, displayedComponents: .date)
                            .onChange(of: beginDate) { _, v in
                                if endDate < v { endDate = v }
                            }
                        DatePicker("結束日期", selection: $endDate, in: beginDate..., displayedComponents: .date)
                    }
                    .disabled(mode.isReadOnly)

                    // MARK: 節次
                    Section("節次") {
                        Picker("開始節次", selection: $beginSectNo) {
                            ForEach(sections) { section in
                                Text(section.displayName).tag(section.sectNo)
                            }
                        }
                        Picker("結束節次", selection: $endSectNo) {
                            ForEach(sections.filter { $0.sectNo >= beginSectNo }) { section in
                                Text(section.displayName).tag(section.sectNo)
                            }
                        }
                        .onChange(of: beginSectNo) { _, v in
                            if endSectNo < v { endSectNo = v }
                        }
                    }
                    .disabled(mode.isReadOnly)

                    // MARK: 請假事由
                    Section("請假事由") {
                        TextField("請填寫請假原因（必填）", text: $reason, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    .disabled(mode.isReadOnly)

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
                    .disabled(mode.isReadOnly)

                    // MARK: 佐證文件
                    Section("佐證文件") {
                        ForEach(existingDocs) { doc in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.fileRawName)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    if let docNa = doc.docNa, !docNa.isEmpty {
                                        Text(docNa)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    Task { await downloadProofDoc(doc) }
                                } label: {
                                    if downloadingDocSn == doc.leaveApplyDocSn {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "square.and.arrow.down")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(downloadingDocSn != nil)
                            }
                        }

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
                        } else if !mode.isReadOnly {
                            Button {
                                showDocPicker = true
                            } label: {
                                Label(existingDocs.isEmpty ? "選擇佐證文件（選填）" : "替換佐證文件", systemImage: "paperclip")
                            }
                        }
                    }

                    // MARK: 送出
                    if !mode.isReadOnly {
                        Section {
                        Button {
                            Task { await submitLeave() }
                        } label: {
                            HStack {
                                Spacer()
                                if isSubmitting {
                                    ProgressView()
                                } else {
                                    Text(mode.leaveApplySn == nil ? "送出申請" : "儲存假單").bold()
                                }
                                Spacer()
                            }
                        }
                        .disabled(!canSubmit)
                        }
                    }
                }
            }
        }
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
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
                let normalizedExt = ext.isEmpty ? "pdf" : ext
                let mimeType = UTType(filenameExtension: normalizedExt)?.preferredMIMEType ?? "application/octet-stream"
                proofFileItem = ProofFileItem(
                    data: data,
                    filename: url.lastPathComponent,
                    ext: normalizedExt,
                    mimeType: mimeType
                )
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
        .sheet(item: $downloadedProofFile) { file in
            NavigationStack {
                VStack(spacing: 16) {
                    Image(systemName: "doc.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(file.filename)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    ShareLink(item: file.url) {
                        Label("分享或儲存檔案", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .navigationTitle("佐證文件")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - Helpers

    private var alertTitle: String {
        if case .success = submitResult { return mode.leaveApplySn == nil ? "假單建立成功" : "假單儲存成功" }
        return "送出失敗"
    }

    private var alertMessage: String {
        switch submitResult {
        case .success(let sn):
            if mode.leaveApplySn == nil {
                return "假單已建立，序號：\(sn)。\n請等待各級主管審核。"
            }
            return "假單已儲存，序號：\(sn)。"
        case .failure(let msg): return msg
        case nil: return ""
        }
    }

    private func loadReferenceData() async {
        isLoading = true
        loadError = nil

        async let hyTask    = leaveService.fetchAcademicYears()
        async let kindsTask = leaveService.fetchLeaveKinds()
        async let examKindsTask = leaveService.fetchExamKinds()
        async let refLeavesTask = leaveService.fetchRefLeaves()
        async let sectionsTask = leaveService.fetchSections()
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
            examKinds = try await examKindsTask
            refLeaves = try await refLeavesTask
            sections = try await sectionsTask
            if let leaveApplySn = mode.leaveApplySn {
                let detail = try await leaveService.fetchLeaveDetail(leaveApplySn: leaveApplySn)
                apply(detail)
            } else {
                syncSelectedSections()
                selectedExamKind = isExamLeave ? examKinds.first : nil
                syncSelectedLeaveType()
            }
        } catch {
            loadError = error.localizedDescription
            isLoading = false
            return
        }

        if let profile = try? await profileTask {
            if phoneNumber.isEmpty { phoneNumber = profile.phone }
            if emailAccount.isEmpty { emailAccount = profile.email }
        }

        isLoading = false
    }

    private func apply(_ detail: LeaveDetail) {
        selectedHy = academicYears.first(where: { $0.hy == detail.hy }) ?? selectedHy
        selectedHt = detail.ht
        selectedCategory = leaveKindCategories.first(where: { $0.value == detail.leaveKind }) ?? selectedCategory
        selectedExamKind = detail.examKind == 0 ? nil : examKinds.first(where: { $0.value == detail.examKind })
        selectedLeaveType = refLeaves.first(where: { $0.refLeaveSn == detail.refLeaveSn })
        beginDate = parseAPIDate(detail.beginDate) ?? beginDate
        endDate = parseAPIDate(detail.endDate) ?? beginDate
        beginSectNo = detail.beginSectNo
        endSectNo = detail.endSectNo
        reason = detail.leaveReason
        phoneNumber = detail.phoneNumber
        emailAccount = detail.emailAccount
        officialLeaveSn = detail.officialLeaveSn
        existingDocs = detail.leaveApplyDocs
        syncSelectedSections()
        syncSelectedLeaveType()
    }

    private func isValidEmail(_ email: String) -> Bool {
        let t = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("@") && t.contains(".")
    }

    private func syncSelectedLeaveType() {
        let options = availableLeaveTypes
        if let selectedLeaveType, options.contains(selectedLeaveType) {
            return
        }
        selectedLeaveType = options.first
    }

    private func syncSelectedSections() {
        guard let firstSection = sections.first, let lastSection = sections.last else { return }
        if !sections.contains(where: { $0.sectNo == beginSectNo }) {
            beginSectNo = firstSection.sectNo
        }
        if !sections.contains(where: { $0.sectNo == endSectNo }) {
            endSectNo = lastSection.sectNo
        }
        if endSectNo < beginSectNo {
            endSectNo = beginSectNo
        }
    }

    private func parseAPIDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: string) { return date }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private func downloadProofDoc(_ doc: LeaveApplyDoc) async {
        guard downloadingDocSn == nil else { return }
        downloadingDocSn = doc.leaveApplyDocSn
        defer { downloadingDocSn = nil }

        do {
            let downloaded = try await leaveService.downloadLeaveApplyDoc(leaveApplyDocSn: doc.leaveApplyDocSn)
            let filename = downloaded.filename.isEmpty ? doc.fileRawName : downloaded.filename
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try downloaded.data.write(to: url, options: .atomic)
            downloadedProofFile = DownloadedProofFile(url: url, filename: filename)
        } catch {
            submitResult = .failure(error.localizedDescription)
        }
    }

    private func submitLeave() async {
        guard let hy = selectedHy, let category = selectedCategory, let leaveType = selectedLeaveType else { return }
        isSubmitting = true

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        do {
            let leaveApplySn = try await leaveService.submitLeave(
                leaveApplySn: mode.leaveApplySn ?? 0,
                academicYear: hy.hy,
                semester: selectedHt,
                leaveKind: category.value,
                examKind: selectedExamKind?.value ?? 0,
                refLeaveSn: leaveType.refLeaveSn,
                officialLeaveSn: officialLeaveSn,
                beginDate: df.string(from: beginDate),
                endDate: df.string(from: endDate),
                beginSectNo: beginSectNo,
                endSectNo: endSectNo,
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                phoneNumber: phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                emailAccount: emailAccount.trimmingCharacters(in: .whitespacesAndNewlines),
                proofFileData: proofFileItem?.data,
                proofFileName: proofFileItem?.filename ?? "proof.pdf",
                proofFileExt: proofFileItem?.ext ?? "pdf",
                proofFileMimeType: proofFileItem?.mimeType ?? "application/octet-stream",
                proofRefDocSn: selectedDocMapping?.refDocSn ?? 0
            )
            if mode.leaveApplySn == nil {
                reason = ""
            }
            proofFileItem = nil
            submitResult = .success(leaveApplySn)
            onSaved?()
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
    @State private var statResult: LeaveStatResult?
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

                    if let statResult {
                        Section("請假統計") {
                            HStack {
                                Text("總請假節次")
                                Spacer()
                                Text("\(statResult.sumLeaveSect) 節")
                                    .font(.body.weight(.semibold))
                            }
                            HStack {
                                Text("已核定節次")
                                Spacer()
                                Text("\(statResult.sumLeaveSectYes) 節")
                                    .foregroundStyle(.green)
                            }
                            HStack {
                                Text("未核定節次")
                                Spacer()
                                Text("\(statResult.sumLeaveSectNo) 節")
                                    .foregroundStyle(.orange)
                            }
                        }

                        let courses = statResult.statLeaveCouList
                        if courses.isEmpty {
                            Section("課程明細") {
                                Text("尚無課程統計").foregroundStyle(.secondary)
                            }
                        } else {
                            Section("課程明細") {
                                ForEach(courses) { course in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(course.courseName)
                                                    .font(.body.weight(.medium))
                                                if !course.teacherName.isEmpty {
                                                    Text(course.teacherName)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                if !course.scheduleText.isEmpty {
                                                    Text(course.scheduleText)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            VStack(alignment: .trailing, spacing: 2) {
                                                Text("\(course.cntLeaveSect) 節")
                                                    .font(.body.weight(.semibold))
                                                if course.cntLeaveSectYes > 0 || course.cntLeaveSectNo > 0 {
                                                    Text("核定 \(course.cntLeaveSectYes) / 未核 \(course.cntLeaveSectNo)")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    } else {
                        Section("請假統計") {
                            Text("尚無請假紀錄").foregroundStyle(.secondary)
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
        statResult = nil
        do {
            statResult = try await leaveService.fetchLeaveStat(academicYear: hy.hy, semester: selectedHt)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
