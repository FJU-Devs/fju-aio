import Foundation
import os.log

actor TronClassAPIService {
    static let shared = TronClassAPIService()
    
    private let baseURL = "https://elearn2.fju.edu.tw"
    private let authService = TronClassAuthService.shared
    private let networkService = NetworkService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fju.aio", category: "TronClassAPI")
    
    private init() {}
    
    // MARK: - Todos
    
    func getTodos() async throws -> [TodoItem] {
        logger.info("📋 Fetching todos...")
        let session = try await authService.getValidSession()
        
        let url = URL(string: "\(baseURL)/api/todos")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(session.sessionId, forHTTPHeaderField: "x-session-id")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("zh-Hant", forHTTPHeaderField: "Accept-Language")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("capacitor://localhost", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) TronClass/common", forHTTPHeaderField: "User-Agent")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        
        do {
            let (data, httpResponse) = try await networkService.performRequest(request)
            try handleHTTPError(httpResponse)
            
            let response = try JSONDecoder().decode(TodosResponse.self, from: data)
            logger.info("✅ Fetched \(response.todo_list.count) todos")
            return response.todo_list
        } catch let error as TronClassAPIError {
            throw error
        } catch {
            logger.error("❌ Failed to fetch todos: \(error.localizedDescription)")
            throw TronClassAPIError.networkError(error)
        }
    }
    
    // MARK: - Error Handling
    
    private func handleHTTPError(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            logger.error("❌ Unauthorized (401)")
            throw TronClassAPIError.unauthorized
        default:
            logger.error("❌ HTTP error: \(response.statusCode)")
            throw TronClassAPIError.invalidResponse
        }
    }
}
