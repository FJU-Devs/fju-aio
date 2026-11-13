import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apply — 4-Step Wizard

struct LeaveApplyWizard: View {
    private let leaveService = LeaveService.shared
    @Environment(\.fjuService) private var fjuService

    static let stepTitles = ["假別與時間", "事由與聯絡", "選擇課程", "確認送出"]

    // Wizard navigation
    @State private var step: Int = 0           // 0=rules modal, 1–4 = wizard steps
    @State private var showRulesModal = true

    // Reference data (fetched on load)
    @State private var isLoadingRef = true
    @State private var loadRefError: String?
    @State private var academicYears: [HyRecord] = []
    @State private var leaveSubtypes: [LeaveKind] = []        // 事假, 病假, …
    @State private var sections: [CourseSection] = []
    @State private var famTypes: [FamTypeItem] = []
    @State private var famLevels: [FamLevelItem] = []
    @State private var contact: StudentContact?
    @State private var hasLoadedRef = false

    // Timetable used to pick leave periods by course
    @State private var timetable: [Course] = []
    @State private var timetableSemester = ""
    @State private var isLoadingTimetable = false

    // Wizard draft shared across steps
    @State private var draft = LeaveWizardDraft()

    // Step 3 data
    @State private var selCouCourses: [LeaveSelCouCourse] = []
    @State private var selectedEntries: Set<String> = []      // key = "\(jonCouSn)-\(couDate)-\(sectNo)"

    // Step 3/4 loading
    @State private var isProcessing = false
    @State private var processError: String?

    // After wizard completes
    @State private var didSubmit = false
    @State private var submittedApplyNo = ""

    // Leaving the wizard
    @State private var showDiscardConfirm = false
    @State private var isDiscarding = false
    @State private var discardError: String?
    @Environment(\.dismiss) private var dismiss

    /// Whether leaving now would throw away user input or a server-side draft.
    private var hasUnsavedInput: Bool {
        guard !didSubmit else { return false }
        return draft.leaveApplySn > 0 ||
            step >= 2 ||
            !draft.leaveReason.isEmpty ||
            draft.proofFileData != nil
    }

    private var semesterKey: String { "\(draft.hy)-\(draft.ht)" }

    var body: some View {
        Group {
            if isLoadingRef {
                ProgressView("載入中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadRefError {
                ContentUnavailableView {
                    Label("載入失敗", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重試") { Task { await loadRef() } }
                        .buttonStyle(.bordered)
                }
            } else if didSubmit {
                SubmitSuccessView(
                    applyNo: submittedApplyNo,
                    onNewApplication: {
                        // Reset wizard to start a new application, keeping reference-data defaults
                        draft = LeaveWizardDraft()
                        applyDefaults()
                        selCouCourses = []
                        selectedEntries = []
                        processError = nil
                        didSubmit = false
                        step = 1
                        showRulesModal = false
                    },
                    onDone: { dismiss() }
                )
            } else if step >= 1 {
                wizardContent
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .disabled(isDiscarding)
        .overlay {
            if isDiscarding {
                ProgressView("正在刪除草稿…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            guard !hasLoadedRef else { return }
            await loadRef()
        }
        .onChange(of: semesterKey) { _, _ in
            guard hasLoadedRef else { return }
            Task { await loadTimetable() }
        }
        .navigationBarBackButtonHidden(true)
        // Make sure swipe-back can't bypass the discard flow (incl. the iOS 26 full-width swipe).
        .interactivePopGestureDisabled(hasUnsavedInput || isProcessing || isDiscarding)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    requestExit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .fontWeight(.semibold)
                        Text("返回")
                    }
                }
                .disabled(isProcessing || isDiscarding)
                .accessibilityLabel("返回")
            }
        }
        .confirmationDialog("要放棄這份假單嗎？", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("放棄並離開", role: .destructive) { discardAndExit() }
            Button("繼續填寫", role: .cancel) {}
        } message: {
            Text(draft.leaveApplySn > 0
                 ? "已填寫的內容將不會保留，暫存的假單草稿也會一併刪除。"
                 : "已填寫的內容將不會保留。")
        }
        .alert("刪除假單草稿失敗", isPresented: Binding(
            get: { discardError != nil },
            set: { if !$0 { discardError = nil } }
        )) {
            Button("重試") { discardAndExit() }
            Button("仍要離開", role: .destructive) { dismiss() }
        } message: {
            Text("\(discardError ?? "")\n若仍要離開，暫存的草稿可能會留在學校系統中。")
        }
        .sheet(isPresented: $showRulesModal, onDismiss: {
            // Rules were not acknowledged — there is no step to show, so leave the wizard.
            if step == 0 { dismiss() }
        }) {
            LeaveRulesModal(
                onAcknowledge: {
                    step = 1
                    showRulesModal = false
                },
                onCancel: {
                    showRulesModal = false
                }
            )
            .interactiveDismissDisabled()
        }
    }

    private func requestExit() {
        if hasUnsavedInput {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    private func discardAndExit() {
        let sn = draft.leaveApplySn
        guard sn > 0 && !didSubmit else {
            dismiss()
            return
        }
        // Delete the unsubmitted server draft before leaving; on failure let the user retry or leave anyway.
        isDiscarding = true
        Task {
            do {
                try await leaveService.deleteLeave(leaveApplySn: sn)
                isDiscarding = false
                draft.leaveApplySn = 0
                dismiss()
            } catch {
                isDiscarding = false
                discardError = error.localizedDescription
            }
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var wizardContent: some View {
        Group {
            switch step {
            case 1:
                LeaveTimeStepView(
                    draft: $draft,
                    academicYears: academicYears,
                    leaveSubtypes: leaveSubtypes,
                    sections: sections,
                    famTypes: famTypes,
                    famLevels: famLevels,
                    timetable: timetable,
                    isLoadingTimetable: isLoadingTimetable
                )
            case 2:
                LeaveDetailsStepView(
                    draft: $draft,
                    leaveSubtypes: leaveSubtypes,
                    sections: sections
                )
                // Freeze inputs while the draft POST is in flight so the server copy matches what's shown.
                .disabled(isProcessing)
            case 3:
                LeaveCoursesStepView(
                    courses: selCouCourses,
                    selectedEntries: $selectedEntries,
                    sections: sections
                )
                .disabled(isProcessing)
            default:
                LeaveConfirmStepView(
                    draft: draft,
                    leaveSubtypes: leaveSubtypes,
                    courses: selCouCourses,
                    selectedEntries: selectedEntries,
                    sections: sections
                )
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            WizardProgressHeader(step: step, titles: Self.stepTitles)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let err = processError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let hint = advanceHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                if step > 1 {
                    Button {
                        // Keep leaveApplySn: if the user edits anything, the next forward pass
                        // updates the existing server draft instead of creating a duplicate.
                        withAnimation { step -= 1 }
                        processError = nil
                    } label: {
                        Text("上一步")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: 120)
                    .disabled(isProcessing)
                }

                Button {
                    Task {
                        if step < 4 { await advanceStep() } else { await finalSubmit() }
                    }
                } label: {
                    ZStack {
                        // Keep the label's size while the spinner shows.
                        Text(step < 4 ? "下一步" : "送出假單")
                            .bold()
                            .opacity(isProcessing ? 0 : 1)
                        if isProcessing {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isProcessing || !canAdvance)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Validation

    private var selectedSubtype: LeaveKind? {
        leaveSubtypes.first { $0.value == draft.refLeaveSn }
    }

    private var hasRequiredFamilyFields: Bool {
        selectedSubtype?.requiresFamilyFields != true ||
            (draft.famTypeNo != nil && draft.famLevelNo != nil)
    }

    private var hasValidPeriodRange: Bool {
        guard draft.beginDate == draft.endDate else { return true }
        let b = sections.firstIndex { $0.sectNo == draft.beginSectNo } ?? 0
        let e = sections.firstIndex { $0.sectNo == draft.endSectNo } ?? 0
        return e >= b
    }

    private var canAdvance: Bool {
        switch step {
        case 1:
            return !draft.beginDate.isEmpty &&
                !draft.endDate.isEmpty &&
                hasRequiredFamilyFields &&
                hasValidPeriodRange
        case 2:
            return !draft.leaveReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !draft.phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty &&
                isValidEmail(draft.emailAccount)
        default:
            return true   // Step 3 can proceed even with no courses selected
        }
    }

    /// Explains what is still missing when 下一步 is disabled.
    private var advanceHint: String? {
        guard !canAdvance else { return nil }
        switch step {
        case 1:
            if !hasRequiredFamilyFields { return "請選擇親屬關係類型與等級" }
            if !hasValidPeriodRange { return "結束節次不可早於開始節次" }
            return "請選擇請假日期"
        case 2:
            if draft.leaveReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "請填寫請假事由" }
            if draft.phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty { return "請填寫聯絡電話" }
            return "請填寫有效的電子郵件"
        default:
            return nil
        }
    }

    private func isValidEmail(_ email: String) -> Bool {
        let t = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("@") && t.contains(".")
    }

    // MARK: - Navigation logic

    private func advanceStep() async {
        processError = nil
        switch step {
        case 2:
            isProcessing = true
            do {
                let sn: Int
                let fields = draft.serverFields
                if draft.leaveApplySn > 0 && draft.lastSubmittedFields == fields {
                    // Already sent on a previous forward pass and unchanged — reuse it
                    sn = draft.leaveApplySn
                } else {
                    // POST /StuLeave: creates the draft (sn 0) or updates the existing one
                    sn = try await leaveService.submitLeave(
                        leaveApplySn: draft.leaveApplySn,
                        academicYear: draft.hy,
                        semester: draft.ht,
                        leaveKind: draft.leaveKind,
                        examKind: 0,
                        refLeaveSn: draft.refLeaveSn,
                        beginDate: draft.beginDate,
                        endDate: draft.endDate,
                        beginSectNo: draft.beginSectNo,
                        endSectNo: draft.endSectNo,
                        reason: draft.leaveReason,
                        phoneNumber: draft.phoneNumber,
                        emailAccount: draft.emailAccount,
                        famTypeNo: draft.famTypeNo ?? 0,
                        famLevelNo: draft.famLevelNo ?? 0,
                        proofFileData: draft.proofFileData,
                        proofFileExt: draft.proofFileExt
                    )
                    draft.leaveApplySn = sn
                    draft.lastSubmittedFields = fields
                }
                // Fetch (or re-fetch) matched courses
                selCouCourses = try await leaveService.fetchSelCouCourses(leaveApplySn: sn)
                // Pre-select all matched dates
                selectedEntries = Set(selCouCourses.flatMap { course in
                    course.leaveDates.map { d in leaveEntryKey(course: course, date: d) }
                })
                withAnimation { step = 3 }
            } catch {
                processError = error.localizedDescription
            }
            isProcessing = false
        case 3:
            // POST /StuLeave/{sn}/SelCou with selected entries
            isProcessing = true
            do {
                let session = try await SISAuthService.shared.getValidSession()
                let entries = buildSelCouEntries(stuNo: session.empNo)
                try await leaveService.selectCourses(entries, forLeave: draft.leaveApplySn)
                withAnimation { step = 4 }
            } catch {
                processError = error.localizedDescription
            }
            isProcessing = false
        default:
            withAnimation { step += 1 }
        }
    }

    private func finalSubmit() async {
        processError = nil
        isProcessing = true
        do {
            try await leaveService.confirmLeave(leaveApplySn: draft.leaveApplySn)
            submittedApplyNo = draft.applyNo.isEmpty ? "\(draft.leaveApplySn)" : draft.applyNo
            didSubmit = true
        } catch {
            processError = error.localizedDescription
        }
        isProcessing = false
    }

    // MARK: - Helpers

    private func buildSelCouEntries(stuNo: String) -> [SelCouPostEntry] {
        // One entry per course. Each entry contains all selected seqTims + all unique couDates.
        selCouCourses.compactMap { course in
            let selectedDates = course.leaveDates.filter {
                selectedEntries.contains(leaveEntryKey(course: course, date: $0))
            }
            guard !selectedDates.isEmpty else { return nil }

            // seqTims: one item per selected date+period
            let seqTims = selectedDates.map { d in
                let sectionName = sections.first { $0.sectNo == d.sectNo }?.sectNa ?? "D\(d.sectNo)"
                return SelCouSeqTim(
                    section: sectionName,
                    leaveSeqTimSn: 0,
                    leaveApplySn: draft.leaveApplySn,
                    jonCouSn: course.jonCouSn,
                    avaCouSn: course.avaCouSn,
                    stuNo: stuNo,
                    couDate: d.couDate + "T00:00:00",
                    couWek: course.couWek,
                    sectNo: d.sectNo
                )
            }

            // couDates: plain date strings, one per unique date
            let couDates = Array(Set(selectedDates.map { $0.couDate + "T00:00:00" })).sorted()

            return SelCouPostEntry(
                jonCouSn: course.jonCouSn,
                avaCouSn: course.avaCouSn,
                stuNo: stuNo,
                couWek: course.couWek,
                seqTims: seqTims,
                couDates: couDates
            )
        }
    }

    // MARK: - Reference data load

    private func loadRef() async {
        isLoadingRef = true
        loadRefError = nil
        do {
            async let hyTask       = leaveService.fetchAcademicYears()
            async let subtypeTask  = leaveService.fetchRefLeave()
            async let sectTask     = leaveService.fetchCourseSections()
            async let famTypeTask  = leaveService.fetchFamTypes()
            async let famLevelTask = leaveService.fetchFamLevels()
            async let contactTask  = leaveService.fetchStudentContact()

            academicYears  = try await hyTask
            leaveSubtypes  = try await subtypeTask
            sections       = try await sectTask
            famTypes = (try? await famTypeTask) ?? []
            famLevels = (try? await famLevelTask) ?? []
            contact = (try? await contactTask) ?? nil

            applyDefaults()
            hasLoadedRef = true
        } catch {
            loadRefError = error.localizedDescription
        }
        isLoadingRef = false
        if hasLoadedRef { await loadTimetable() }
    }

    /// Loads the timetable of the draft's semester (cache first) for picking periods by course.
    /// Failure is non-fatal: the time step falls back to plain period pickers.
    private func loadTimetable() async {
        let semester = semesterKey
        guard semester != timetableSemester else { return }
        timetableSemester = semester
        if let cached = AppCache.shared.getCourses(semester: semester) {
            timetable = cached
            return
        }
        timetable = []
        isLoadingTimetable = true
        let fetched = (try? await fjuService.fetchCourses(semester: semester)) ?? []
        guard semester == semesterKey else { return }
        if !fetched.isEmpty {
            AppCache.shared.setCourses(fetched, semester: semester)
        } else {
            // Allow a retry the next time this semester is selected.
            timetableSemester = ""
        }
        timetable = fetched
        isLoadingTimetable = false
    }

    /// Fills a fresh draft with defaults derived from the loaded reference data.
    private func applyDefaults() {
        let current = LeaveSemesterDefaults.current()
        draft.hy = LeaveSemesterDefaults.defaultYear(in: academicYears)?.hy ?? current.year
        draft.ht = current.term
        if let firstSubtype = leaveSubtypes.first {
            draft.refLeaveSn = firstSubtype.value
        }
        if sections.count >= 2 {
            draft.beginSectNo = sections.first?.sectNo ?? 1
            draft.endSectNo   = sections.last?.sectNo ?? 9
        }

        // Default dates to today so the button is enabled without requiring picker interaction
        let today = LeaveDateFormat.api.string(from: Date())
        if draft.beginDate.isEmpty { draft.beginDate = today }
        if draft.endDate.isEmpty   { draft.endDate   = today }

        // Pre-fill contact info
        if let contact {
            if draft.phoneNumber.isEmpty { draft.phoneNumber = contact.phoneNumber ?? "" }
            if draft.emailAccount.isEmpty { draft.emailAccount = contact.emailAccount ?? "" }
        }
    }
}

// MARK: - Shared helpers

private func leaveEntryKey(course: LeaveSelCouCourse, date: LeaveSelCouDate) -> String {
    "\(course.jonCouSn)-\(date.couDate)-\(date.sectNo)"
}

private enum LeaveDateFormat {
    /// "yyyy-MM-dd" as the leave API expects.
    static let api: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = CurrentSemester.taipeiCalendar
        f.timeZone = CurrentSemester.taipeiCalendar.timeZone
        return f
    }()

    /// "10/16（四）"
    static func short(_ apiDate: String) -> String {
        guard let d = api.date(from: String(apiDate.prefix(10))) else { return apiDate }
        let comps = CurrentSemester.taipeiCalendar.dateComponents([.month, .day], from: d)
        return "\(comps.month ?? 0)/\(comps.day ?? 0)（\(weekdayName(of: d))）"
    }

    /// "2026/10/16（四）"
    static func long(_ apiDate: String) -> String {
        guard let d = api.date(from: String(apiDate.prefix(10))) else { return apiDate }
        let comps = CurrentSemester.taipeiCalendar.dateComponents([.year, .month, .day], from: d)
        return "\(comps.year ?? 0)/\(comps.month ?? 0)/\(comps.day ?? 0)（\(weekdayName(of: d))）"
    }

    /// Monday = 1 … Sunday = 7, matching `Course.dayOfWeekNumber`.
    static func weekdayNumber(of date: Date) -> Int {
        let weekday = CurrentSemester.taipeiCalendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }

    static func weekdayName(of date: Date) -> String {
        ["一", "二", "三", "四", "五", "六", "日"][weekdayNumber(of: date) - 1]
    }
}

private extension Array where Element == CourseSection {
    func label(for sectNo: Int) -> String {
        first { $0.sectNo == sectNo }?.sectNa ?? "D\(sectNo)"
    }

    func timeLabel(for sectNo: Int) -> String {
        guard let s = first(where: { $0.sectNo == sectNo }) else { return "D\(sectNo)" }
        return "\(s.sectNa) \(s.beginTime)"
    }

    /// Number of periods from `begin` to `end` inclusive, in list order.
    func count(from begin: Int, to end: Int) -> Int {
        guard let b = firstIndex(where: { $0.sectNo == begin }),
              let e = firstIndex(where: { $0.sectNo == end }), e >= b else { return 0 }
        return e - b + 1
    }
}

// MARK: - Progress header

private struct WizardProgressHeader: View {
    let step: Int
    let titles: [String]

    private var clampedStep: Int { Swift.min(Swift.max(step, 1), titles.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(titles[clampedStep - 1])
                    .font(.headline)
                Spacer()
                Text("\(clampedStep) / \(titles.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(1...titles.count, id: \.self) { n in
                    Capsule()
                        .fill(n <= clampedStep ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .animation(.easeInOut, value: clampedStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("步驟 \(clampedStep)/\(titles.count)：\(titles[clampedStep - 1])")
    }
}

// MARK: - Rules Modal (Step 0)

private struct LeaveRulesModal: View {
    let onAcknowledge: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("學生請假，事假、普通傷病假以曠課時數計，不得超過各科目學期上課總時數三分之一，超過者依學則規定辦理。")
                        .font(.subheadline)
                } header: {
                    Text("第二十六條")
                }

                Section {
                    Label {
                        Text("學生未依規定辦理請假手續或逾假未到者，以曠課論。學期曠課達上課總時數三分之一者，不得參加期末考試，並應依學則規定辦理。")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Color.red.opacity(0.08))
                } header: {
                    Text("第二十七條")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("學生請假規則")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onAcknowledge) {
                    Text("我已瞭解請假相關規定")
                        .bold()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
    }
}

// MARK: - Step 1: 假別與時間

private struct LeaveTimeStepView: View {
    @Binding var draft: LeaveWizardDraft
    let academicYears: [HyRecord]
    let leaveSubtypes: [LeaveKind]
    let sections: [CourseSection]
    let famTypes: [FamTypeItem]
    let famLevels: [FamLevelItem]
    let timetable: [Course]
    let isLoadingTimetable: Bool

    /// A timetable course placed onto the leave API's period list.
    struct DayCourse: Identifiable {
        let course: Course
        let beginIndex: Int
        let endIndex: Int
        var id: String { "\(course.id)-\(beginIndex)" }
    }

    private var isBereavementLeave: Bool {
        leaveSubtypes.first { $0.value == draft.refLeaveSn }?.requiresFamilyFields ?? false
    }

    private var beginDate: Date { LeaveDateFormat.api.date(from: draft.beginDate) ?? Date() }
    private var endDate: Date { LeaveDateFormat.api.date(from: draft.endDate) ?? Date() }

    private var beginDateBinding: Binding<Date> {
        Binding(
            get: { beginDate },
            set: { newValue in
                draft.beginDate = LeaveDateFormat.api.string(from: newValue)
                // Cascade end date if it falls before begin
                if endDate < newValue {
                    draft.endDate = draft.beginDate
                }
                normalizeSections()
            }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { endDate },
            set: { newValue in
                draft.endDate = LeaveDateFormat.api.string(from: newValue)
                normalizeSections()
            }
        )
    }

    private var isSameDay: Bool { draft.beginDate == draft.endDate }

    private var beginIndex: Int { sections.firstIndex { $0.sectNo == draft.beginSectNo } ?? 0 }
    private var endIndex: Int { sections.firstIndex { $0.sectNo == draft.endSectNo } ?? Swift.max(sections.count - 1, 0) }

    private var endSectionOptions: [CourseSection] {
        isSameDay ? Array(sections.dropFirst(beginIndex)) : sections
    }

    private func normalizeSections() {
        if isSameDay && endIndex < beginIndex {
            draft.endSectNo = draft.beginSectNo
        }
    }

    // MARK: Timetable mapping

    private static func normalizedTime(_ t: String) -> String {
        let parts = t.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)) else { return t }
        return String(format: "%02d:%02d", h, m)
    }

    /// Index into `sections` for a timetable period, matched by start time, then by name.
    private func sectionIndex(forPeriod period: Int) -> Int? {
        guard let slot = FJUPeriod.slot(for: period) else { return nil }
        if let i = sections.firstIndex(where: { Self.normalizedTime($0.beginTime) == slot.start }) {
            return i
        }
        return sections.firstIndex {
            $0.sectNa == slot.code || $0.sectNa == slot.label || $0.sectNa == "第\(slot.label)節"
        }
    }

    private func courses(on date: Date) -> [DayCourse] {
        let weekday = LeaveDateFormat.weekdayNumber(of: date)
        var seen = Set<String>()
        return timetable
            .filter { $0.hasScheduledTime && $0.dayOfWeekNumber == weekday }
            .compactMap { course -> DayCourse? in
                guard let b = sectionIndex(forPeriod: course.startPeriod),
                      let e = sectionIndex(forPeriod: course.endPeriod), e >= b else { return nil }
                let item = DayCourse(course: course, beginIndex: b, endIndex: e)
                return seen.insert(item.id).inserted ? item : nil
            }
            .sorted { $0.beginIndex < $1.beginIndex }
    }

    private var beginDayCourses: [DayCourse] { courses(on: beginDate) }
    private var endDayCourses: [DayCourse] { courses(on: endDate) }

    private func isIncluded(_ c: DayCourse) -> Bool {
        c.beginIndex >= beginIndex && c.endIndex <= endIndex
    }

    private func setRange(_ b: Int, _ e: Int) {
        guard sections.indices.contains(b), sections.indices.contains(e) else { return }
        draft.beginSectNo = sections[b].sectNo
        draft.endSectNo = sections[e].sectNo
    }

    /// Tapping a course grows the (contiguous) leave range to include it, or trims it off an edge.
    private func toggle(_ c: DayCourse, in dayCourses: [DayCourse]) {
        let included = dayCourses.filter(isIncluded)
        if isIncluded(c) {
            let others = included.filter { $0.id != c.id }
            guard let firstBegin = others.map(\.beginIndex).min(),
                  let lastEnd = others.map(\.endIndex).max() else {
                // Only course in range: narrow the range to exactly this course.
                setRange(c.beginIndex, c.endIndex)
                return
            }
            if c.beginIndex < firstBegin {
                // First course: trim the start up to the next course, keep the end.
                setRange(firstBegin, endIndex)
            } else if c.endIndex > lastEnd {
                // Last course: trim the end back to the previous course, keep the start.
                setRange(beginIndex, lastEnd)
            } else {
                // The range must stay contiguous, so a middle course means "only this one".
                setRange(c.beginIndex, c.endIndex)
            }
        } else if included.isEmpty {
            setRange(c.beginIndex, c.endIndex)
        } else {
            // Grow the current range (incl. any hand-picked periods) to cover this course.
            setRange(Swift.min(c.beginIndex, beginIndex), Swift.max(c.endIndex, endIndex))
        }
    }

    // MARK: Body

    var body: some View {
        Form {
            Section {
                Picker("請假性質", selection: $draft.leaveKind) {
                    Text("一般請假").tag(1)
                    Text("考試請假").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Picker("假別", selection: $draft.refLeaveSn) {
                    ForEach(leaveSubtypes) { subtype in
                        Text(subtype.label).tag(subtype.value)
                    }
                }

                if isBereavementLeave {
                    Picker("親屬關係類型", selection: Binding(
                        get: { draft.famTypeNo ?? 0 },
                        set: { draft.famTypeNo = $0 == 0 ? nil : $0 }
                    )) {
                        Text("請選擇").tag(0)
                        ForEach(famTypes) { t in Text(t.label).tag(t.value) }
                    }
                    .disabled(famTypes.isEmpty)

                    Picker("親屬關係等級", selection: Binding(
                        get: { draft.famLevelNo ?? 0 },
                        set: { draft.famLevelNo = $0 == 0 ? nil : $0 }
                    )) {
                        Text("請選擇").tag(0)
                        ForEach(famLevels) { l in Text(l.label).tag(l.value) }
                    }
                    .disabled(famLevels.isEmpty)

                    if famTypes.isEmpty || famLevels.isEmpty {
                        Label("親屬關係選項載入失敗，請返回後重試。", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("假別")
            } footer: {
                if draft.leaveKind == 1 {
                    Text("請於規定時間內申請，逾期無法補登。公假及考試假不適用此流程，請洽各系辦公室。")
                } else {
                    Text("考試期間（期中考、期末考等）請假使用。")
                }
            }

            Section("請假日期") {
                DatePicker("開始日期", selection: beginDateBinding, displayedComponents: .date)
                DatePicker("結束日期", selection: endDateBinding, in: beginDate..., displayedComponents: .date)
            }

            if isSameDay {
                dayCoursesSection
            } else {
                multiDaySection
            }

            if academicYears.count > 0 {
                Section {
                    Picker("學年度", selection: $draft.hy) {
                        ForEach(academicYears) { hy in
                            Text(hy.hyNa).tag(hy.hy)
                        }
                    }
                    Picker("學期", selection: $draft.ht) {
                        Text("第 1 學期").tag(1)
                        Text("第 2 學期").tag(2)
                    }
                } header: {
                    Text("學期")
                } footer: {
                    Text("預設為本學期，通常不需更改。")
                }
            }
        }
        .onChange(of: draft.beginSectNo) { _, _ in normalizeSections() }
    }

    // MARK: Single day

    @ViewBuilder
    private var dayCoursesSection: some View {
        let dayCourses = beginDayCourses
        Section {
            if isLoadingTimetable && timetable.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在載入課表…").foregroundStyle(.secondary)
                }
            } else if dayCourses.isEmpty {
                Label(timetable.isEmpty ? "無法取得課表，請手動選擇節次" : "這天沒有排課",
                      systemImage: "calendar.badge.minus")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dayCourses) { item in
                    DayCourseRow(
                        item: item,
                        sections: sections,
                        isIncluded: isIncluded(item)
                    ) {
                        withAnimation(.snappy) { toggle(item, in: dayCourses) }
                    }
                }
            }
        } header: {
            HStack {
                Text("\(LeaveDateFormat.short(draft.beginDate)) 的課程")
                Spacer()
                if !sections.isEmpty {
                    Button("整天") {
                        withAnimation(.snappy) { setRange(0, sections.count - 1) }
                    }
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                }
            }
        } footer: {
            if !dayCourses.isEmpty {
                Text("點選課程即可設定請假節次。請假時段需連續，中間的課程會一併請假。")
            }
        }

        periodSection(beginCourses: dayCourses, endCourses: dayCourses)
    }

    // MARK: Multiple days

    @ViewBuilder
    private var multiDaySection: some View {
        periodSection(beginCourses: beginDayCourses, endCourses: endDayCourses)
    }

    @ViewBuilder
    private func periodSection(beginCourses: [DayCourse], endCourses: [DayCourse]) -> some View {
        Section {
            Picker(isSameDay ? "開始節次" : "第一天從", selection: $draft.beginSectNo) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { idx, s in
                    Text(periodOptionLabel(s, index: idx, courses: beginCourses)).tag(s.sectNo)
                }
            }
            Picker(isSameDay ? "結束節次" : "最後一天到", selection: $draft.endSectNo) {
                ForEach(endSectionOptions) { s in
                    let idx = sections.firstIndex(of: s) ?? 0
                    Text(periodOptionLabel(s, index: idx, courses: endCourses)).tag(s.sectNo)
                }
            }
        } header: {
            Text(isSameDay ? "節次" : "請假節次")
        } footer: {
            Text(summaryText)
        }
    }

    private func periodOptionLabel(_ s: CourseSection, index: Int, courses: [DayCourse]) -> String {
        let base = "\(s.sectNa)  \(s.beginTime)–\(s.endTime)"
        guard let c = courses.first(where: { $0.beginIndex <= index && index <= $0.endIndex }) else { return base }
        return "\(base)・\(c.course.name)"
    }

    private var summaryText: String {
        guard sections.indices.contains(beginIndex), sections.indices.contains(endIndex) else { return "" }
        let b = sections[beginIndex], e = sections[endIndex]
        if isSameDay {
            let n = Swift.max(endIndex - beginIndex + 1, 0)
            return "\(LeaveDateFormat.short(draft.beginDate)) \(b.sectNa) \(b.beginTime) – \(e.sectNa) \(e.endTime)，共 \(n) 節"
        }
        return "\(LeaveDateFormat.short(draft.beginDate)) \(b.sectNa) \(b.beginTime) 起，至 \(LeaveDateFormat.short(draft.endDate)) \(e.sectNa) \(e.endTime) 止"
    }
}

private struct DayCourseRow: View {
    let item: LeaveTimeStepView.DayCourse
    let sections: [CourseSection]
    let isIncluded: Bool
    let onTap: () -> Void

    private var periodText: String {
        let b = sections[item.beginIndex], e = sections[item.endIndex]
        let name = item.beginIndex == item.endIndex ? b.sectNa : "\(b.sectNa)–\(e.sectNa)"
        return "\(name)・\(b.beginTime)–\(e.endTime)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: item.course.color))
                    .frame(width: 4, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.course.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(periodText)
                        if !item.course.location.isEmpty {
                            Text("・\(item.course.location)")
                        }
                        if item.course.weeks == "單" || item.course.weeks == "雙" {
                            Text("\(item.course.weeks)週")
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isIncluded ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Step 2: 事由與聯絡

private struct LeaveDetailsStepView: View {
    @Binding var draft: LeaveWizardDraft
    let leaveSubtypes: [LeaveKind]
    let sections: [CourseSection]

    @State private var showDocPicker = false
    @State private var attachmentError: String?
    private let maxAttachmentSize = 10 * 1024 * 1024

    private enum Field: Hashable {
        case reason, phone, email
    }
    @FocusState private var focusedField: Field?

    private var selectedSubtypeLabel: String {
        leaveSubtypes.first { $0.value == draft.refLeaveSn }?.label ?? "—"
    }

    private var timeSummary: String {
        let begin = "\(LeaveDateFormat.short(draft.beginDate)) \(sections.label(for: draft.beginSectNo))"
        if draft.beginDate == draft.endDate {
            return draft.beginSectNo == draft.endSectNo ? begin : "\(begin)–\(sections.label(for: draft.endSectNo))"
        }
        return "\(begin) – \(LeaveDateFormat.short(draft.endDate)) \(sections.label(for: draft.endSectNo))"
    }

    private var emailLooksInvalid: Bool {
        let t = draft.emailAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !(t.contains("@") && t.contains("."))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("假別", value: selectedSubtypeLabel)
                LabeledContent("時間", value: timeSummary)
            }

            Section {
                TextField("例如：發燒就醫、家中有事…", text: $draft.leaveReason, axis: .vertical)
                    .lineLimit(4...8)
                    .focused($focusedField, equals: .reason)
                    .onChange(of: draft.leaveReason) { _, v in
                        if v.count > 500 { draft.leaveReason = String(v.prefix(500)) }
                    }
            } header: {
                Text("請假事由")
            } footer: {
                HStack {
                    Text("必填")
                    Spacer()
                    Text("\(draft.leaveReason.count)/500").monospacedDigit()
                }
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField("聯絡電話", text: $draft.phoneNumber)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .focused($focusedField, equals: .phone)
                }
                HStack(spacing: 12) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField("電子郵件", text: $draft.emailAccount)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .email)
                }
            } header: {
                Text("聯絡資料")
            } footer: {
                if emailLooksInvalid {
                    Text("電子郵件格式不正確").foregroundStyle(.red)
                } else {
                    Text("已自動帶入學籍資料，可視需要修改。")
                }
            }

            Section {
                if !draft.proofFileName.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: draft.proofFileExt == "pdf" ? "doc.richtext.fill" : "photo.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(draft.proofFileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            draft.proofFileData = nil
                            draft.proofFileName = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除佐證文件")
                    }
                    Button("更換檔案") { showDocPicker = true }
                } else {
                    Button {
                        showDocPicker = true
                    } label: {
                        Label("加入佐證文件", systemImage: "paperclip")
                    }
                }
            } header: {
                Text("佐證文件（選填）")
            } footer: {
                Text("支援 PDF 或圖片，10 MB 以內。部分假別（如病假、喪假）可能需要附上證明。")
            }
        }
        .fileImporter(
            isPresented: $showDocPicker,
            allowedContentTypes: [.pdf, .image, .jpeg, .png],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                guard data.count <= maxAttachmentSize else {
                    attachmentError = "檔案大小不可超過 10 MB。"
                    return
                }
                let ext = url.pathExtension.lowercased()
                draft.proofFileData  = data
                draft.proofFileExt   = ext.isEmpty ? "pdf" : ext
                draft.proofFileName  = url.lastPathComponent
            } else {
                attachmentError = "無法讀取選取的檔案，請重新選擇。"
            }
        }
        .alert("附件無法加入", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("確定", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
    }
}

// MARK: - Step 3: 選擇課程

private struct LeaveCoursesStepView: View {
    let courses: [LeaveSelCouCourse]
    @Binding var selectedEntries: Set<String>
    let sections: [CourseSection]

    private var eligibleCourses: [LeaveSelCouCourse] {
        courses.filter { !$0.leaveDates.isEmpty }
    }

    private var totalCount: Int { eligibleCourses.reduce(0) { $0 + $1.leaveDates.count } }

    var body: some View {
        if eligibleCourses.isEmpty {
            ContentUnavailableView(
                "此時段沒有課程",
                systemImage: "calendar.badge.checkmark",
                description: Text("請假時段內沒有排課，可直接前往下一步。")
            )
        } else {
            List {
                Section {
                    HStack {
                        Text("已選擇")
                        Spacer()
                        Text("\(selectedEntries.count) / \(totalCount) 節")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("系統已依請假時段列出相符的課程並全部勾選，取消勾選的節次不會請假。")
                }

                ForEach(eligibleCourses) { course in
                    courseSection(course)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func courseSection(_ course: LeaveSelCouCourse) -> some View {
        let keys = course.leaveDates.map { leaveEntryKey(course: course, date: $0) }
        let allSelected = keys.allSatisfy(selectedEntries.contains)

        return Section {
            ForEach(course.leaveDates) { d in
                let key = leaveEntryKey(course: course, date: d)
                let isOn = selectedEntries.contains(key)
                Button {
                    if isOn { selectedEntries.remove(key) } else { selectedEntries.insert(key) }
                } label: {
                    HStack {
                        Text(LeaveDateFormat.short(d.couDate))
                            .foregroundStyle(.primary)
                        Text(sections.timeLabel(for: d.sectNo))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        } header: {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.couCNa)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text([course.couNo, course.tchCNa].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・"))
                        .font(.caption)
                }
                Spacer()
                Button(allSelected ? "全不選" : "全選") {
                    if allSelected {
                        keys.forEach { selectedEntries.remove($0) }
                    } else {
                        keys.forEach { selectedEntries.insert($0) }
                    }
                }
                .font(.footnote.weight(.semibold))
            }
            .textCase(nil)
        }
    }
}

// MARK: - Step 4: 確認送出

private struct LeaveConfirmStepView: View {
    let draft: LeaveWizardDraft
    let leaveSubtypes: [LeaveKind]
    let courses: [LeaveSelCouCourse]
    let selectedEntries: Set<String>
    let sections: [CourseSection]

    private var subtypeLabel: String {
        leaveSubtypes.first { $0.value == draft.refLeaveSn }?.label ?? "—"
    }

    private var selectedCourseList: [(course: LeaveSelCouCourse, dates: [LeaveSelCouDate])] {
        courses.compactMap { course in
            let filtered = course.leaveDates.filter { d in
                selectedEntries.contains(leaveEntryKey(course: course, date: d))
            }
            return filtered.isEmpty ? nil : (course, filtered)
        }
    }

    private var totalSelected: Int { selectedCourseList.reduce(0) { $0 + $1.dates.count } }

    private func timeText(date: String, sectNo: Int, useEnd: Bool) -> String {
        guard let s = sections.first(where: { $0.sectNo == sectNo }) else { return LeaveDateFormat.long(date) }
        return "\(LeaveDateFormat.long(date)) \(s.sectNa) \(useEnd ? s.endTime : s.beginTime)"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(subtypeLabel)
                            .font(.title2.weight(.bold))
                        Text(draft.leaveKind == 1 ? "一般請假" : "考試請假")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        Spacer()
                    }
                    Text("\(draft.hy) 學年度 第 \(draft.ht) 學期")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("請假時間") {
                LabeledContent("開始", value: timeText(date: draft.beginDate, sectNo: draft.beginSectNo, useEnd: false))
                LabeledContent("結束", value: timeText(date: draft.endDate, sectNo: draft.endSectNo, useEnd: true))
            }

            Section("請假事由") {
                Text(draft.leaveReason)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("聯絡資料") {
                LabeledContent("電話", value: draft.phoneNumber)
                LabeledContent("電子郵件", value: draft.emailAccount)
                LabeledContent("佐證文件", value: draft.proofFileName.isEmpty ? "未上傳" : draft.proofFileName)
            }

            Section {
                if selectedCourseList.isEmpty {
                    Label("未選取任何課程", systemImage: "calendar.badge.minus")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(selectedCourseList, id: \.course.id) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.course.couCNa)
                                .font(.body.weight(.medium))
                            Text(datesText(entry.dates))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text(selectedCourseList.isEmpty ? "請假課程" : "請假課程（\(selectedCourseList.count) 門・\(totalSelected) 節）")
            } footer: {
                Text("送出後將進入簽核流程，可於「歷史假單」查看進度或撤銷。")
            }
        }
        .listStyle(.insetGrouped)
    }

    /// "10/16（四）D1、D2；10/17（五）D3"
    private func datesText(_ dates: [LeaveSelCouDate]) -> String {
        let grouped = Dictionary(grouping: dates, by: \.couDate)
        return grouped.keys.sorted().map { date in
            let sects = (grouped[date] ?? []).map { sections.label(for: $0.sectNo) }.joined(separator: "、")
            return "\(LeaveDateFormat.short(date)) \(sects)"
        }
        .joined(separator: "；")
    }
}

// MARK: - Submit Success View

private struct SubmitSuccessView: View {
    let applyNo: String
    let onNewApplication: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: applyNo)
            Text("假單已送出")
                .font(.title2.weight(.bold))
            Text("假單號 #\(applyNo)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("請等待授課教師及各級主管審核，\n可於「歷史假單」查看簽核進度。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: 10) {
                Button(action: onDone) {
                    Text("完成").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onNewApplication) {
                    Text("再申請一筆").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
