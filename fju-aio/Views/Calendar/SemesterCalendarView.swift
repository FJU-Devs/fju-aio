import SwiftUI

struct SemesterCalendarView: View {
    @Environment(\.fjuService) private var service
    @State private var events: [CalendarEvent] = []
    @State private var isLoading = true
    @State private var selectedCategory: CalendarEvent.EventCategory?
    @State private var errorMessage: String?

//    private var filteredEvents: [CalendarEvent] {
//        let filtered = selectedCategory == nil ? events : events.filter { $0.category == selectedCategory }
//        return filtered.sorted { $0.startDate < $1.startDate }
//    }
    
    private var filteredEvents: [CalendarEvent] {
        let filtered = selectedCategory == nil ? events : events.filter { $0.category == selectedCategory }
        // Show events from 30 days ago onwards
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        return filtered.filter { $0.startDate >= thirtyDaysAgo }
            .sorted { $0.startDate < $1.startDate }
    }

    private var groupedByMonth: [(String, [CalendarEvent])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"

        let grouped = Dictionary(grouping: filteredEvents) { event in
            formatter.string(from: event.startDate)
        }

        // Sort by actual date, not string
        return grouped.sorted { first, second in
            // Get first event from each group to compare dates
            guard let firstEvent = first.value.first,
                  let secondEvent = second.value.first else {
                return first.key < second.key
            }
            return firstEvent.startDate < secondEvent.startDate
        }
    }


    var body: some View {
        List {
            // Category filter
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip(label: "全部", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(CalendarEvent.EventCategory.allCases, id: \.self) { category in
                            filterChip(label: category.rawValue, isSelected: selectedCategory == category) {
                                selectedCategory = category
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

            // Error message
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            // Empty state
            if !isLoading && filteredEvents.isEmpty && errorMessage == nil {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("目前沒有行事曆事件")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }

            // Events grouped by month
            ForEach(groupedByMonth, id: \.0) { month, monthEvents in
                Section(month) {
                    ForEach(monthEvents) { event in
                        CalendarEventRow(event: event)
                    }
                }
            }
        }
        .navigationTitle("學期行事曆")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView("載入中...")
            }
        }
        .task {
            await loadEvents()
        }
        .refreshable {
            await loadEvents()
        }
    }

    private func loadEvents() async {
        isLoading = true
        errorMessage = nil
        
        do {
            print("🔍 Starting calendar fetch...")
            events = try await service.fetchCalendarEvents(semester: "113-2")
            print("✅ Fetched \(events.count) calendar events")
            
            // Debug: Print date range of events
            if let earliest = events.min(by: { $0.startDate < $1.startDate }),
               let latest = events.max(by: { $0.startDate < $1.startDate }) {
                print("📅 Event date range: \(earliest.startDate) to \(latest.startDate)")
            }
            
            if events.isEmpty {
                print("⚠️ No events returned from service")
            }
        } catch {
            print("❌ Calendar fetch error: \(error)")
            errorMessage = "載入失敗: \(error.localizedDescription)"
        }
        
        isLoading = false
    }

    private func filterChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(isSelected ? Color.accentColor : Color(.systemGray5), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
