import SwiftUI

struct SemesterCalendarView: View {
    @Environment(\.fjuService) private var service
    @State private var events: [CalendarEvent] = []
    @State private var isLoading = true
    @State private var selectedCategory: CalendarEvent.EventCategory?

    private var filteredEvents: [CalendarEvent] {
        let filtered = selectedCategory == nil ? events : events.filter { $0.category == selectedCategory }
        return filtered.sorted { $0.startDate < $1.startDate }
    }

    private var groupedByMonth: [(String, [CalendarEvent])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"

        let grouped = Dictionary(grouping: filteredEvents) { event in
            formatter.string(from: event.startDate)
        }

        return grouped.sorted { $0.key < $1.key }
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
            do {
                events = try await service.fetchCalendarEvents(semester: "113-2")
            } catch {}
            isLoading = false
        }
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
