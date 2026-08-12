import Foundation
@testable import Nuxie

/// Helper methods for matching and validating requests in tests
struct RequestMatchers {
    
    // MARK: - Path Matchers
    
    /// Match request by exact path
    static func pathEquals(_ path: String) -> StubURLProtocol.Matcher {
        return { request in
            return request.url?.path == path
        }
    }
    
    /// Match request by path prefix
    static func pathStartsWith(_ prefix: String) -> StubURLProtocol.Matcher {
        return { request in
            request.url?.path.hasPrefix(prefix) ?? false
        }
    }
    
    /// Match request by path containing substring
    static func pathContains(_ substring: String) -> StubURLProtocol.Matcher {
        return { request in
            request.url?.path.contains(substring) ?? false
        }
    }
    
    // MARK: - Method Matchers
    
    /// Match request by HTTP method and path
    static func methodAndPath(_ method: String, _ path: String) -> StubURLProtocol.Matcher {
        return { request in
            return request.httpMethod == method && request.url?.path == path
        }
    }
    
    /// Match POST request to specific path
    static func post(_ path: String) -> StubURLProtocol.Matcher {
        return methodAndPath("POST", path)
    }
    
    /// Match GET request to specific path
    static func get(_ path: String) -> StubURLProtocol.Matcher {
        return methodAndPath("GET", path)
    }
    
    // MARK: - Header Matchers
    
    /// Match request containing specific header
    static func hasHeader(_ key: String, value: String? = nil) -> StubURLProtocol.Matcher {
        return { request in
            guard let headerValue = request.value(forHTTPHeaderField: key) else {
                return false
            }
            if let expectedValue = value {
                return headerValue == expectedValue
            }
            return true
        }
    }
    
    /// Match request with gzip compression
    static func hasGzipEncoding() -> StubURLProtocol.Matcher {
        return hasHeader("Content-Encoding", value: "gzip")
    }
    
    // MARK: - Query Matchers
    
    /// Match request containing query parameter
    static func hasQueryParam(_ name: String, value: String? = nil) -> StubURLProtocol.Matcher {
        return { request in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let queryItems = components.queryItems else {
                return false
            }
            
            let item = queryItems.first { $0.name == name }
            guard let foundItem = item else { return false }
            
            if let expectedValue = value {
                return foundItem.value == expectedValue
            }
            return true
        }
    }
    
    // MARK: - Body Matchers
    
    /// Match request with JSON body containing specific key
    static func bodyContainsKey(_ key: String) -> StubURLProtocol.Matcher {
        return { request in
            guard let body = extractBody(from: request) else { return false }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    return json[key] != nil
                }
            } catch {
                // Not valid JSON
            }
            return false
        }
    }
    
    /// Match request with JSON body containing key-value pair
    static func bodyContains(key: String, value: Any) -> StubURLProtocol.Matcher {
        return { request in
            guard let body = extractBody(from: request) else { return false }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let jsonValue = json[key] {
                    // Simple equality check for basic types
                    if let stringValue = value as? String,
                       let jsonString = jsonValue as? String {
                        return stringValue == jsonString
                    }
                    if let intValue = value as? Int,
                       let jsonInt = jsonValue as? Int {
                        return intValue == jsonInt
                    }
                    if let boolValue = value as? Bool,
                       let jsonBool = jsonValue as? Bool {
                        return boolValue == jsonBool
                    }
                }
            } catch {
                // Not valid JSON
            }
            return false
        }
    }
    
    /// Match request with specific distinct ID in body
    static func hasDistinctId(_ distinctId: String) -> StubURLProtocol.Matcher {
        return bodyContains(key: "distinctId", value: distinctId)
    }
    
    /// Match request with API key in body
    static func hasApiKeyInBody(_ apiKey: String) -> StubURLProtocol.Matcher {
        return bodyContains(key: "apiKey", value: apiKey)
    }
    
    // MARK: - Composite Matchers
    
    /// Combine multiple matchers with AND logic
    static func all(_ matchers: StubURLProtocol.Matcher...) -> StubURLProtocol.Matcher {
        return { request in
            return matchers.allSatisfy { $0(request) }
        }
    }
    
    /// Combine multiple matchers with OR logic
    static func any(_ matchers: StubURLProtocol.Matcher...) -> StubURLProtocol.Matcher {
        return { request in
            matchers.contains { $0(request) }
        }
    }
    
    // MARK: - Helpers
    
    /// Extract body data from request, handling gzip if needed
    private static func extractBody(from request: URLRequest) -> Data? {
        guard var body = request.httpBody else { return nil }
        
        // Decompress if gzipped
        if request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
            body = (try? body.gunzipped()) ?? body
        }
        
        return body
    }
}
