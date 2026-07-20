import Foundation

/// Protocol for custom property sanitization
public protocol NuxiePropertiesSanitizer {
    /// Custom sanitization logic for event properties
    /// - Parameter properties: Properties to sanitize
    /// - Returns: Sanitized properties dictionary
    func sanitize(_ properties: [String: Any]) -> [String: Any]
}

/// Built-in sanitization utilities
public class EventSanitizer {
    
    /// Maximum string length for property values
    private static let maxStringLength = 1000
    
    /// Maximum nested depth for dictionaries/arrays
    private static let maxNestingDepth = 10
    
    /// Stage 1: Early data type sanitization
    /// Converts platform-specific types to JSON-serializable types
    /// Called before property enrichment
    /// - Parameter properties: Raw properties dictionary
    /// - Returns: Sanitized properties with valid JSON types
    public static func sanitizeDataTypes(_ properties: [String: Any]) -> [String: Any] {
        return sanitizeValue(properties, depth: 0) as? [String: Any] ?? [:]
    }
    
    /// Stage 2: Custom business logic sanitization  
    /// Applies user-defined sanitization rules
    /// Called after property enrichment
    /// - Parameters:
    ///   - properties: Enriched properties dictionary
    ///   - sanitizer: Optional custom sanitizer
    /// - Returns: Final sanitized properties
    public static func sanitizeProperties(
        _ properties: [String: Any],
        customSanitizer: NuxiePropertiesSanitizer? = nil
    ) -> [String: Any] {
        guard let sanitizer = customSanitizer else {
            return properties
        }
        
        return sanitizer.sanitize(properties)
    }
    
    // MARK: - Private Implementation
    
    /// Recursively sanitize any value to make it JSON-serializable
    private static func sanitizeValue(_ value: Any, depth: Int) -> Any? {
        // Prevent infinite recursion - allow one extra level for leaf values
        guard depth <= maxNestingDepth + 1 else {
            LogWarning("Max nesting depth reached during sanitization, truncating")
            return nil
        }
        
        switch value {
        // Basic JSON types - pass through
        case let string as String:
            return sanitizeString(string)
            
        case let number as NSNumber:
            // Handle Bool separately to preserve type
            if number === kCFBooleanTrue as NSNumber || number === kCFBooleanFalse as NSNumber {
                return number.boolValue
            }
            return number
            
        case is Int, is Int32, is Int64, is Float, is Double:
            return value
            
        case is Bool:
            return value
            
        // Platform types - convert to JSON-compatible
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
            
        case let url as URL:
            return url.absoluteString
            
        case let uuid as UUID:
            return uuid.uuidString
            
        case let data as Data:
            // Convert data to base64 string (be careful with large data)
            if data.count > 1024 {
                LogWarning("Large data object in properties, truncating")
                return data.prefix(1024).base64EncodedString()
            }
            return data.base64EncodedString()
            
        // Collections - recurse
        case let array as [Any]:
            return sanitizeArray(array, depth: depth)
            
        case let dict as [String: Any]:
            return sanitizeDictionary(dict, depth: depth)
            
        // NSNull - preserve
        case is NSNull:
            return value
            
        // nil - convert to NSNull for JSON
        case Optional<Any>.none:
            return NSNull()
            
        // Everything else - try to convert to string or drop
        default:
            if let stringValue = (value as? CustomStringConvertible)?.description {
                LogDebug("Converting non-JSON type to string: \(type(of: value))")
                return sanitizeString(stringValue)
            } else {
                LogWarning("Dropping non-serializable property value: \(type(of: value))")
                return nil
            }
        }
    }
    
    /// Sanitize string values (length limits, invalid characters)
    private static func sanitizeString(_ string: String) -> String {
        var sanitized = string
        
        // Truncate long strings
        if sanitized.count > maxStringLength {
            sanitized = String(sanitized.prefix(maxStringLength))
            LogDebug("Truncated long string property to \(maxStringLength) characters")
        }
        
        // Remove null characters that can break JSON
        sanitized = sanitized.replacingOccurrences(of: "\0", with: "")
        
        return sanitized
    }
    
    /// Sanitize array recursively
    private static func sanitizeArray(_ array: [Any], depth: Int) -> [Any] {
        return array.compactMap { sanitizeValue($0, depth: depth + 1) }
    }
    
    /// Sanitize dictionary recursively
    private static func sanitizeDictionary(_ dict: [String: Any], depth: Int) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        
        for (key, value) in dict {
            // Sanitize key
            let sanitizedKey = sanitizeString(key)
            
            // Sanitize value
            if let sanitizedValue = sanitizeValue(value, depth: depth + 1) {
                sanitized[sanitizedKey] = sanitizedValue
            }
        }
        
        return sanitized
    }
    
    /// Validate that a dictionary can be JSON serialized
    public static func isValidJSONObject(_ object: Any) -> Bool {
        return JSONSerialization.isValidJSONObject(object)
    }
}

/// Default sanitizer implementations for common use cases
public class DefaultPropertiesSanitizers {
    
    /// Privacy-focused sanitizer that removes common PII fields
    public static let privacy = PrivacySanitizer()
    
    /// Compliance sanitizer for strict data regulations
    public static let compliance = ComplianceSanitizer()
    
    /// Development sanitizer that logs all transformations
    public static let debug = DebugSanitizer()
}

/// Remove common PII fields
public class PrivacySanitizer: NuxiePropertiesSanitizer {
    private static let maxNestingDepth = 10
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"(?i)([\p{L}\p{M}\p{N}.!#$%&'*+/=?^_`{|}~-]+)@([\p{L}\p{N}](?:[\p{L}\p{M}\p{N}-]{0,61}[\p{L}\p{M}\p{N}])?(?:\.[\p{L}\p{N}](?:[\p{L}\p{M}\p{N}-]{0,61}[\p{L}\p{M}\p{N}])?)*)"#
    )

    /// Lowercased, punctuation-independent field names removed at every level.
    private let piiFields = Set([
        "email", "emailaddress", "workemail", "personalemail", "contactemail",
        "phone", "phonenumber", "telephone", "telephonenumber", "mobile",
        "mobilephone", "mobilephonenumber", "cell", "cellphone", "workphone",
        "homephone", "contactphone", "contactphonenumber", "ssn",
        "socialsecuritynumber", "creditcard", "password", "apikey", "token",
        "secret", "name", "fullname", "firstname", "middlename", "lastname",
        "givenname", "familyname", "legalname", "displayname", "surname",
        "address", "street", "streetaddress", "addressline", "addressline1",
        "addressline2", "homeaddress", "workaddress", "postaladdress",
        "mailingaddress", "shippingaddress", "billingaddress", "postalcode",
        "postcode", "zip", "zipcode", "address1", "address2", "street1",
        "street2"
    ])
    private let allowedNameFields = Set([
        "filename", "hostname", "microphone", "namespace", "username"
    ])
    private let piiLeafTokens = Set([
        "address", "email", "phone", "ssn", "telephone"
    ])
    private let personNameQualifierTokens = Set([
        "billing", "cardholder", "contact", "customer", "identity", "person",
        "profile", "recipient", "shipping", "user"
    ])
    private let piiSuffixes = Set([
        "address1", "address2", "addressline1", "addressline2", "emailaddress",
        "phonenumber", "postalcode", "streetaddress", "streetline1",
        "streetline2", "zipcode"
    ])
    
    public func sanitize(_ properties: [String: Any]) -> [String: Any] {
        sanitizeDictionary(properties, depth: 0)
    }

    private func sanitizeDictionary(
        _ properties: [String: Any],
        depth: Int
    ) -> [String: Any] {
        guard depth <= Self.maxNestingDepth + 1 else { return [:] }

        var cleaned: [String: Any] = [:]
        for (key, value) in properties {
            guard !isPIIField(key) else { continue }
            if let sanitizedValue = sanitizeValue(value, depth: depth + 1) {
                cleaned[key] = sanitizedValue
            }
        }
        return cleaned
    }

    private func sanitizeValue(_ value: Any, depth: Int) -> Any? {
        guard depth <= Self.maxNestingDepth + 1 else { return nil }

        switch value {
        case let dictionary as [String: Any]:
            return sanitizeDictionary(dictionary, depth: depth)
        case let array as [Any]:
            return array.compactMap { sanitizeValue($0, depth: depth + 1) }
        case let stringValue as String:
            return maskEmails(in: stringValue)
        default:
            return value
        }
    }

    private func isPIIField(_ field: String) -> Bool {
        let normalized = normalizedFieldName(field)
        if allowedNameFields.contains(normalized) {
            return false
        }
        if piiFields.contains(normalized) {
            return true
        }

        let tokens = fieldTokens(field)
        guard let last = tokens.last else { return false }
        if piiLeafTokens.contains(last) {
            return true
        }
        if last == "name",
           tokens.dropLast().contains(where: personNameQualifierTokens.contains) {
            return true
        }

        if tokens.count >= 2 {
            for length in 2...min(3, tokens.count) {
                if piiSuffixes.contains(tokens.suffix(length).joined()) {
                    return true
                }
            }
        }
        return false
    }

    private func fieldTokens(_ field: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousWasLowercaseOrNumber = false

        func finishCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
        }

        for character in field {
            guard character.isLetter || character.isNumber else {
                finishCurrentToken()
                previousWasLowercaseOrNumber = false
                continue
            }
            if character.isUppercase && previousWasLowercaseOrNumber {
                finishCurrentToken()
            }
            current.append(contentsOf: String(character).lowercased())
            previousWasLowercaseOrNumber = character.isLowercase || character.isNumber
        }
        finishCurrentToken()
        return tokens
    }

    private func normalizedFieldName(_ field: String) -> String {
        field.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    
    private func maskEmails(in value: String) -> String {
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = Self.emailPattern.matches(in: value, range: fullRange)
        guard !matches.isEmpty else { return value }

        var masked = value
        for match in matches.reversed() {
            guard let usernameRange = Range(match.range(at: 1), in: masked) else {
                continue
            }
            let username = masked[usernameRange]
            let replacement = username.count >= 2
                ? String(username.prefix(2)) + "***"
                : "***"
            masked.replaceSubrange(usernameRange, with: replacement)
        }
        return masked
    }
}

/// Strict compliance sanitizer
public class ComplianceSanitizer: NuxiePropertiesSanitizer {
    public func sanitize(_ properties: [String: Any]) -> [String: Any] {
        let privacyCleaned = DefaultPropertiesSanitizers.privacy.sanitize(properties)
        return removeEmptyValues(from: privacyCleaned) as? [String: Any] ?? [:]
    }

    private func removeEmptyValues(from value: Any) -> Any? {
        switch value {
        case let stringValue as String:
            return stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : stringValue
        case is NSNull:
            return nil
        case let dictionary as [String: Any]:
            var cleaned: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                if let nestedValue = removeEmptyValues(from: nestedValue) {
                    cleaned[key] = nestedValue
                }
            }
            return cleaned
        case let array as [Any]:
            return array.compactMap(removeEmptyValues)
        default:
            return value
        }
    }
}

/// Debug sanitizer that logs all operations
public class DebugSanitizer: NuxiePropertiesSanitizer {
    public func sanitize(_ properties: [String: Any]) -> [String: Any] {
        LogDebug("Input properties: \(properties.keys.joined(separator: ", "))")
        
        let cleaned = properties.filter { key, value in
            let keep = !(value is NSNull)
            if !keep {
                LogDebug("Removing null property: \(key)")
            }
            return keep
        }
        
        LogDebug("Output properties: \(cleaned.keys.joined(separator: ", "))")
        return cleaned
    }
}
