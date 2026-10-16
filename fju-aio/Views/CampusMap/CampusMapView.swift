import SwiftUI
import MapKit
import CoreLocation

// CampusBuilding / CampusAmenity are defined in CampusBuilding.swift

// MARK: - Palette

/// Three roles only: neutral (everything by default), the app accent (your
/// buildings, primary actions), and orange reserved for "in class right now".
/// Amenity types are told apart by icon, not colour.
private enum MarkerTone {
    case neutral, accent, now

    var fill: Color {
        switch self {
        case .neutral: return Color(.systemBackground)
        case .accent: return .accentColor
        case .now: return .orange
        }
    }

    var foreground: Color {
        self == .neutral ? .primary : .white
    }

    /// Badge fill inside glass panels, where a solid white/black disc looks heavy.
    var badgeFill: Color {
        self == .neutral ? Color.primary.opacity(0.1) : fill
    }

    /// The colour actions and highlights take on in this state.
    var tint: Color {
        self == .now ? .orange : .accentColor
    }
}

// MARK: - Selection & Filters

/// `nonisolated` so the Hashable conformance isn't main-actor-isolated: MapKit
/// hashes/compares selection tags off the main thread, which traps otherwise.
nonisolated private enum MapItem: Hashable, Sendable {
    case building(String)   // building code
    case amenity(String)    // amenity id
}

nonisolated private enum MapFilter: CaseIterable, Identifiable, Sendable {
    case all, myCourses, food, stores

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .myCourses: return "我的課程"
        case .food: return "學餐"
        case .stores: return "便利商店"
        }
    }

    var icon: String {
        switch self {
        case .all: return "map"
        case .myCourses: return "book.closed.fill"
        case .food: return "fork.knife"
        case .stores: return "bag.fill"
        }
    }
}

/// How much detail markers show, driven by camera distance so the campus
/// overview stays readable and detail appears as you zoom in.
private enum MarkerDetail: Comparable {
    case overview   // only your buildings get a code; others are dots
    case codes      // every building shows its code
    case names      // codes + names under markers
}

private let campusRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 25.0357, longitude: 121.4322),
    span: MKCoordinateSpan(latitudeDelta: 0.0068, longitudeDelta: 0.0068)
)

// MARK: - Campus Map View

struct CampusMapView: View {
    /// When set, the map will fly to and highlight this building on appear.
    var highlightLocation: String? = nil

    @Environment(\.fjuService) private var service
    @AppStorage("preferredMapsApp") private var preferredMapsApp = "apple"

    private let buildings = CampusBuildingRegistry.all
    private let amenities = CampusAmenity.all

    @State private var cameraPosition: MapCameraPosition = .region(campusRegion)
    /// Visible latitude span, used to decide how much detail markers show.
    @State private var visibleSpan: Double = campusRegion.span.latitudeDelta
    @State private var selection: MapItem?
    @State private var filter: MapFilter = .all
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var locationManager = CLLocationManager()

    @State private var courses: [Course] = []
    @State private var coursesByBuilding: [String: [Course]] = [:]
    @State private var currentCourse: Course?

    // MARK: Derived state

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var markerDetail: MarkerDetail {
        if visibleSpan < 0.0028 { return .names }
        if visibleSpan < 0.0055 { return .codes }
        return .overview
    }

    private var selectedBuilding: CampusBuilding? {
        guard case .building(let code) = selection else { return nil }
        return buildings.first { $0.code == code }
    }

    private var selectedAmenity: CampusAmenity? {
        guard case .amenity(let id) = selection else { return nil }
        return amenities.first { $0.id == id }
    }

    private var currentCourseBuilding: CampusBuilding? {
        guard let course = currentCourse else { return nil }
        return CampusBuildingRegistry.building(for: course.location)
    }

    private func hasCourses(_ building: CampusBuilding) -> Bool {
        !(coursesByBuilding[building.code]?.isEmpty ?? true)
    }

    private var visibleBuildings: [CampusBuilding] {
        buildings.filter { building in
            if selection == .building(building.code) { return true }
            switch filter {
            case .all: return true
            case .myCourses: return hasCourses(building)
            case .food, .stores: return false
            }
        }
    }

    private var visibleAmenities: [CampusAmenity] {
        amenities.filter { amenity in
            if selection == .amenity(amenity.id) { return true }
            switch filter {
            case .all: return true
            case .myCourses: return false
            case .food: return amenity.category == .foodCourt
            case .stores: return amenity.category == .convenienceStore
            }
        }
    }

    private var buildingResults: [CampusBuilding] {
        buildings.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.code.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var amenityResults: [CampusAmenity] {
        amenities.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.category.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: Body

    var body: some View {
        Map(position: $cameraPosition, selection: $selection) {
            UserAnnotation()

            ForEach(visibleBuildings) { building in
                buildingAnnotation(building)
            }

            ForEach(visibleAmenities) { amenity in
                amenityAnnotation(amenity)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleSpan = context.region.span.latitudeDelta
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .animation(.snappy(duration: 0.3), value: selection)
        .animation(.snappy(duration: 0.25), value: isSearching)
        .animation(.snappy(duration: 0.25), value: markerDetail)
        .navigationTitle("校園地圖")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            isSearchFocused = false
            searchText = ""
            if let coordinate = coordinate(for: newValue) {
                withAnimation(.smooth(duration: 0.6)) { fly(to: coordinate) }
            }
        }
        .onAppear {
            // Location permission is requested only when the user taps the locate button.
            loadCoursesFromCache()
            if let location = highlightLocation,
               let building = CampusBuildingRegistry.building(for: location) {
                selection = .building(building.code)
            }
        }
        .task {
            await refreshCoursesIfNeeded()
        }
    }

    // MARK: Annotations

    @MapContentBuilder
    private func buildingAnnotation(_ building: CampusBuilding) -> some MapContent {
        let isSelected = selection == .building(building.code)
        let isCurrent = currentCourseBuilding?.code == building.code
        let isMine = hasCourses(building)
        let style: BuildingMarker.Style = isCurrent ? .current : (isMine ? .mine : .plain)
        let showsCode = isSelected || isCurrent || isMine || markerDetail >= .codes
        let showsName = isSelected || markerDetail == .names

        Annotation(showsName ? building.name : "", coordinate: building.coordinate, anchor: .center) {
            BuildingMarker(code: building.code, style: style, showsCode: showsCode, isSelected: isSelected)
                .onTapGesture { selection = .building(building.code) }
                .accessibilityElement()
                .accessibilityLabel(building.name)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
        .tag(MapItem.building(building.code))
    }

    @MapContentBuilder
    private func amenityAnnotation(_ amenity: CampusAmenity) -> some MapContent {
        let isSelected = selection == .amenity(amenity.id)
        let showsName = isSelected || markerDetail == .names

        Annotation(showsName ? amenity.name : "", coordinate: amenity.coordinate, anchor: .center) {
            AmenityMarker(category: amenity.category, isSelected: isSelected)
                .onTapGesture { selection = .amenity(amenity.id) }
                .accessibilityElement()
                .accessibilityLabel(amenity.name)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
        .tag(MapItem.amenity(amenity.id))
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(spacing: 8) {
            searchField
            if isSearching {
                SearchResultsList(
                    buildings: buildingResults,
                    amenities: amenityResults,
                    courseCount: { coursesByBuilding[$0.code]?.count ?? 0 },
                    onSelect: { selection = $0 }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                filterChips
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("搜尋建築或地點", text: $searchText)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit { isSearchFocused = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .modifier(GlassOrMaterialBackground(shape: Capsule()))
        .padding(.horizontal, 16)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MapFilter.allCases) { item in
                    FilterChip(
                        title: item.title,
                        icon: item.icon,
                        isSelected: filter == item
                    ) {
                        withAnimation(.snappy) { filter = item }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .trailing, spacing: 10) {
            locateButton

            Group {
                if let building = selectedBuilding {
                    BuildingPanel(
                        building: building,
                        courses: coursesByBuilding[building.code] ?? [],
                        currentCourse: currentCourseBuilding?.code == building.code ? currentCourse : nil,
                        onNavigate: { openNavApp(name: building.name, coordinate: building.coordinate) },
                        onClose: { selection = nil }
                    )
                    .id(building.code)
                } else if let amenity = selectedAmenity {
                    AmenityPanel(
                        amenity: amenity,
                        onNavigate: { openNavApp(name: amenity.name, coordinate: amenity.coordinate) },
                        onClose: { selection = nil }
                    )
                    .id(amenity.id)
                } else if let course = currentCourse, !isSearching {
                    CurrentClassBanner(course: course, hasBuilding: currentCourseBuilding != nil) {
                        if let building = currentCourseBuilding {
                            selection = .building(building.code)
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var locateButton: some View {
        Button {
            locationManager.requestWhenInUseAuthorization()
            withAnimation(.smooth) {
                cameraPosition = .userLocation(followsHeading: false, fallback: .region(campusRegion))
            }
        } label: {
            Image(systemName: cameraPosition.followsUserLocation ? "location.fill" : "location")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassOrMaterialBackground(shape: Circle()))
        .accessibilityLabel("定位目前位置")
        .padding(.trailing, 4)
    }

    // MARK: Helpers

    private func coordinate(for item: MapItem) -> CLLocationCoordinate2D? {
        switch item {
        case .building(let code): return buildings.first { $0.code == code }?.coordinate
        case .amenity(let id): return amenities.first { $0.id == id }?.coordinate
        }
    }

    private func fly(to coordinate: CLLocationCoordinate2D) {
        cameraPosition = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.0035, longitudeDelta: 0.0035)
        ))
    }

    private func setCourses(_ newCourses: [Course]) {
        courses = newCourses
        currentCourse = currentClassNow(from: newCourses)
        var grouped: [String: [Course]] = [:]
        for course in newCourses {
            guard let building = CampusBuildingRegistry.building(for: course.location) else { continue }
            grouped[building.code, default: []].append(course)
        }
        coursesByBuilding = grouped.mapValues { list in
            list.sorted { lhs, rhs in
                if lhs.dayOfWeekNumber != rhs.dayOfWeekNumber {
                    return lhs.dayOfWeekNumber < rhs.dayOfWeekNumber
                }
                if lhs.startPeriod != rhs.startPeriod {
                    return lhs.startPeriod < rhs.startPeriod
                }
                return lhs.name < rhs.name
            }
        }
    }

    private func currentClassNow(from courses: [Course]) -> Course? {
        let now = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        let dayMap: [Int: String] = [2: "一", 3: "二", 4: "三", 5: "四", 6: "五"]
        guard let todayString = dayMap[weekday] else { return nil }

        let nowComponents = calendar.dateComponents([.hour, .minute], from: now)
        guard let hour = nowComponents.hour, let minute = nowComponents.minute else { return nil }
        let currentMinutes = hour * 60 + minute

        return courses.first { course in
            guard course.dayOfWeek == todayString else { return false }
            guard course.hasScheduledTime,
                  let start = minutesSinceMidnight(course.startTimeString),
                  let end = minutesSinceMidnight(course.endTimeString) else { return false }
            return currentMinutes >= start && currentMinutes <= end
        }
    }

    /// Parses an "HH:mm" period time into minutes since midnight.
    private func minutesSinceMidnight(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    @MainActor
    private func loadCoursesFromCache() {
        guard let cached = AppCache.shared.getCourses(semester: CurrentSemester.code()) else { return }
        setCourses(cached)
    }

    private func refreshCoursesIfNeeded() async {
        if !courses.isEmpty { return }
        do {
            let semesters = try await service.fetchAvailableSemesters()
            if !semesters.isEmpty {
                let semester = CurrentSemester.resolve(available: semesters)
                let fetched = try await service.fetchCourses(semester: semester)
                await MainActor.run { setCourses(fetched) }
            }
        } catch {
            // Map is still usable without course data
        }
    }

    private func openNavApp(name: String, coordinate: CLLocationCoordinate2D) {
        if preferredMapsApp == "google",
           let url = URL(string: "comgooglemaps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&directionsmode=walking&zoom=17"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            mapItem.name = name
            mapItem.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
            ])
        }
    }
}

// MARK: - Map Markers

private struct BuildingMarker: View {
    enum Style { case plain, mine, current }

    let code: String
    let style: Style
    let showsCode: Bool
    let isSelected: Bool

    @State private var pulse = false

    private var tone: MarkerTone {
        switch style {
        case .plain: return .neutral
        case .mine: return .accent
        case .current: return .now
        }
    }

    var body: some View {
        ZStack {
            if style == .current {
                Circle()
                    .fill(Color.orange.opacity(0.3))
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulse ? 1.3 : 0.5)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
            }

            if showsCode {
                Text(code)
                    .font(.system(size: isSelected ? 13 : 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.foreground)
                    .padding(.horizontal, isSelected ? 8 : 6)
                    .frame(minWidth: isSelected ? 32 : 24, minHeight: isSelected ? 28 : 20)
                    .background(tone.fill, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(tone == .neutral ? 0.12 : 0),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                    }
            } else {
                Circle()
                    .fill(Color(.systemGray))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
            }
        }
        .shadow(color: .black.opacity(0.2), radius: isSelected ? 4 : 2, y: 1)
        .frame(minWidth: 30, minHeight: 30) // comfortable hit target for dots
        .contentShape(Rectangle())
    }
}

private struct AmenityMarker: View {
    let category: CampusAmenity.Category
    let isSelected: Bool

    var body: some View {
        Image(systemName: category.iconName)
            .font(.system(size: isSelected ? 13 : 10, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: isSelected ? 30 : 22, height: isSelected ? 30 : 22)
            .background(Color(.systemBackground), in: Circle())
            .overlay {
                Circle().strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isSelected ? 2 : 0.5
                )
            }
            .shadow(color: .black.opacity(0.2), radius: isSelected ? 4 : 2, y: 1)
            .frame(minWidth: 30, minHeight: 30)
            .contentShape(Rectangle())
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassOrMaterialBackground(shape: Capsule(), isEnabled: !isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Search Results

private struct SearchResultsList: View {
    let buildings: [CampusBuilding]
    let amenities: [CampusAmenity]
    let courseCount: (CampusBuilding) -> Int
    let onSelect: (MapItem) -> Void

    var body: some View {
        Group {
            if buildings.isEmpty && amenities.isEmpty {
                Text("找不到符合的地點")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !buildings.isEmpty {
                            sectionHeader("建築")
                            ForEach(buildings) { building in
                                let count = courseCount(building)
                                ResultRow(
                                    title: building.name,
                                    subtitle: count > 0 ? "\(building.code) · \(count) 堂課" : building.code,
                                    tone: count > 0 ? .accent : .neutral
                                ) {
                                    Text(building.code)
                                        .font(.system(size: building.code.count > 2 ? 10 : 12, weight: .bold, design: .rounded))
                                } action: {
                                    onSelect(.building(building.code))
                                }
                            }
                        }
                        if !amenities.isEmpty {
                            sectionHeader("餐飲與商店")
                            ForEach(amenities) { amenity in
                                ResultRow(
                                    title: amenity.name,
                                    subtitle: amenity.category.title,
                                    tone: .neutral
                                ) {
                                    Image(systemName: amenity.category.iconName)
                                        .font(.system(size: 13, weight: .semibold))
                                } action: {
                                    onSelect(.amenity(amenity.id))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollDismissesKeyboard(.immediately)
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(GlassOrMaterialBackground(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
        .padding(.horizontal, 16)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

private struct ResultRow<Glyph: View>: View {
    let title: String
    let subtitle: String
    let tone: MarkerTone
    @ViewBuilder let glyph: () -> Glyph
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MarkerBadge(tone: tone, size: 30, content: glyph)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared panel pieces

/// A filled circle with a glyph, matching the map markers' tone.
private struct MarkerBadge<Content: View>: View {
    let tone: MarkerTone
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        Circle()
            .fill(tone.badgeFill)
            .frame(width: size, height: size)
            .overlay { content().foregroundStyle(tone.foreground) }
    }
}

private struct PanelCloseButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct NavigateButton: View {
    let tint: Color
    let action: () -> Void

    var body: some View {
        let label = Label("導航", systemImage: "figure.walk")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)

        if #available(iOS 26.0, *) {
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .tint(tint)
        } else {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(tint)
        }
    }
}

/// Shared header: badge, title/subtitle, navigate, close.
private struct PanelHeader<Badge: View>: View {
    let title: String
    let subtitle: String
    let tint: Color
    let closeLabel: String
    @ViewBuilder let badge: () -> Badge
    let onNavigate: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            badge()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            NavigateButton(tint: tint, action: onNavigate)
            PanelCloseButton(label: closeLabel, action: onClose)
        }
    }
}

private struct PanelContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .modifier(GlassOrMaterialBackground(shape: RoundedRectangle(cornerRadius: 26, style: .continuous)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }
}

// MARK: - Building Panel

private struct BuildingPanel: View {
    let building: CampusBuilding
    let courses: [Course]
    let currentCourse: Course?
    let onNavigate: () -> Void
    let onClose: () -> Void

    private var tone: MarkerTone {
        if currentCourse != nil { return .now }
        return courses.isEmpty ? .neutral : .accent
    }

    /// Multi-slot courses appear once per time slot; count each course once.
    private var distinctCourseCount: Int {
        Set(courses.map { $0.code.isEmpty ? $0.name : $0.code }).count
    }

    private var subtitle: String {
        if let course = currentCourse { return "現在上課 · \(course.name)" }
        return distinctCourseCount > 0 ? "\(building.code) · 你有 \(distinctCourseCount) 門課在這裡" : building.code
    }

    var body: some View {
        PanelContainer {
            PanelHeader(
                title: building.name,
                subtitle: subtitle,
                tint: tone.tint,
                closeLabel: "關閉建築詳細資訊",
                badge: {
                    MarkerBadge(tone: tone, size: 40) {
                        Text(building.code)
                            .font(.system(size: building.code.count > 2 ? 12 : 14, weight: .bold, design: .rounded))
                    }
                },
                onNavigate: onNavigate,
                onClose: onClose
            )

            if !courses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(courses.enumerated()), id: \.offset) { _, course in
                            CourseChip(course: course, isNow: course.id == currentCourse?.id)
                        }
                    }
                }
                // Scroll edge-to-edge inside the panel, clipped by its rounded corners.
                .contentMargins(.horizontal, 14, for: .scrollContent)
                .padding(.horizontal, -14)
            }
        }
    }
}

private struct CourseChip: View {
    let course: Course
    let isNow: Bool

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color(hex: course.color))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(isNow ? "上課中 · \(course.location)" : "\(course.scheduleDescription) · \(course.location)")
                    .font(.caption2)
                    .foregroundStyle(isNow ? Color.orange : .secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Amenity Panel

private struct AmenityPanel: View {
    let amenity: CampusAmenity
    let onNavigate: () -> Void
    let onClose: () -> Void

    @State private var showsFullNote = false

    var body: some View {
        PanelContainer {
            PanelHeader(
                title: amenity.name,
                subtitle: amenity.category.title,
                tint: .accentColor,
                closeLabel: "關閉地點詳細資訊",
                badge: {
                    MarkerBadge(tone: .neutral, size: 40) {
                        Image(systemName: amenity.category.iconName)
                            .font(.system(size: 16, weight: .semibold))
                    }
                },
                onNavigate: onNavigate,
                onClose: onClose
            )

            if !amenity.note.isEmpty {
                Text(amenity.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(showsFullNote ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { showsFullNote.toggle() } }
            }
        }
    }
}

// MARK: - Current Class Banner

private struct CurrentClassBanner: View {
    let course: Course
    let hasBuilding: Bool
    let onLocate: () -> Void

    var body: some View {
        Button(action: onLocate) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                Text("現在上課")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.orange)
                Text(course.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(course.location)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hasBuilding {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!hasBuilding)
        .modifier(GlassOrMaterialBackground(shape: Capsule()))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
    }
}

// MARK: - Glass/Material Background Modifier

/// Applies Liquid Glass on iOS 26+, falls back to .regularMaterial on older OS.
private struct GlassOrMaterialBackground<S: Shape>: ViewModifier {
    let shape: S
    var isEnabled = true

    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }
}

#Preview {
    NavigationStack {
        CampusMapView()
            .environment(\.fjuService, FJUService.shared)
    }
}
