import ActivityKit
import Foundation

struct CourseActivityAttributes: ActivityAttributes {
    let courseName: String
    let courseId: String
    let location: String
    let instructor: String

    struct ContentState: Codable, Hashable {
        var phase: CoursePhase
        var classStartDate: Date
        var classEndDate: Date
    }
}

enum CoursePhase: String, Codable, Hashable {
    case before  // counting down to start
    case during  // counting down to end
    case ended   // class finished
}

extension CourseActivityAttributes {
    var courseDetailURL: URL? {
        var components = URLComponents()
        components.scheme = "fju-aio"
        components.host = "page"
        components.path = "/course"
        components.queryItems = [
            URLQueryItem(name: "courseId", value: courseId)
        ]
        return components.url
    }

    var mapURL: URL? {
        guard !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "fju-aio"
        components.host = "page"
        components.path = "/campusMap"
        components.queryItems = [
            URLQueryItem(name: "location", value: location)
        ]
        return components.url
    }
}
