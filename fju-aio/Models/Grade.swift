import Foundation

struct Grade: Identifiable {
    let id: String
    let courseName: String
    let courseCode: String
    let credits: Int
    let score: Double?
    let semester: String
    let letterGrade: String?
}

struct GPASummary {
    let semesterGPA: Double
    let cumulativeGPA: Double
    let totalCreditsEarned: Int
    let totalCreditsAttempted: Int
    let semester: String
}
