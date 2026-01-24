//
//  S3Service.swift
//  BucketDrop
//
//  Created by Fayaz Ahmed Aralikatti on 12/01/26.
//

import Foundation
import CryptoKit

actor S3Service {
    static let shared = S3Service()
    
    private let settings = SettingsManager.shared
    
    struct S3Error: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    
    struct UploadResult {
        let key: String
        let url: String
    }
    
    // MARK: - URL Generation

    /// Generates the appropriate URL for an object (public or presigned based on settings)
    func getObjectURL(key: String) -> String {
        return buildPublicURL(key: key)
    }

    // MARK: - Upload

    func upload(fileURL: URL, progress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        guard settings.isConfigured else {
            throw S3Error(message: "S3 not configured. Please add credentials in settings.")
        }
        
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let key = "\(UUID().uuidString.prefix(8))-\(filename)"
        
        let contentType = mimeType(for: fileURL.pathExtension)
        
        try await putObject(key: key, data: data, contentType: contentType, progress: progress)
        
        let url = buildPublicURL(key: key)
        return UploadResult(key: key, url: url)
    }
    
    // MARK: - List Objects
    
    func listObjects() async throws -> [S3Object] {
        guard settings.isConfigured else {
            throw S3Error(message: "S3 not configured")
        }
        
        let bucket = settings.bucket
        let host = buildHost()
        let endpoint = buildEndpoint()
        let signingPath = buildSigningPath(objectKey: nil)
        
        let urlString = "\(endpoint)/?list-type=2&max-keys=50"
        guard let url = URL(string: urlString) else {
            throw S3Error(message: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let headers = try signRequest(
            method: "GET",
            path: signingPath,
            query: "list-type=2&max-keys=50",
            headers: ["host": host],
            payload: Data()
        )
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw S3Error(message: "List failed: \(httpResponse.statusCode) - \(body)")
        }
        
        return parseListResponse(data)
    }
    
    // MARK: - Download Object
    
    /// Downloads a file from S3
    /// - Parameters:
    ///   - key: The S3 object key
    ///   - destination: Where to save the file
    ///   - overwrite: If true, overwrites existing file. If false, generates unique name.
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: The actual URL where the file was saved (may differ from destination if not overwriting)
    @discardableResult
    func download(key: String, to destination: URL, overwrite: Bool = false, progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard settings.isConfigured else {
            throw S3Error(message: "S3 not configured")
        }
        
        let host = buildHost()
        let endpoint = buildEndpoint()
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(objectKey: key)
        
        guard let url = URL(string: "\(endpoint)/\(encodedKey)") else {
            throw S3Error(message: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let headers = try signRequest(
            method: "GET",
            path: signingPath,
            query: "",
            headers: ["host": host],
            payload: Data()
        )
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Use bytes(for:) to get progress via AsyncSequence
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw S3Error(message: "Download failed: \(httpResponse.statusCode)")
        }
        
        let expectedLength = httpResponse.expectedContentLength
        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        
        var receivedLength: Int64 = 0
        for try await byte in asyncBytes {
            data.append(byte)
            receivedLength += 1
            
            // Report progress periodically (every 64KB)
            if expectedLength > 0 && receivedLength % 65536 == 0 {
                progress?(Double(receivedLength) / Double(expectedLength))
            }
        }
        
        progress?(1.0)
        
        // Write to destination
        let fileManager = FileManager.default
        var finalDestination = destination
        
        if fileManager.fileExists(atPath: destination.path) {
            if overwrite {
                try fileManager.removeItem(at: destination)
            } else {
                // Generate unique filename
                let directory = destination.deletingLastPathComponent()
                let filename = destination.deletingPathExtension().lastPathComponent
                let ext = destination.pathExtension
                var counter = 1
                
                repeat {
                    let newName = ext.isEmpty ? "\(filename) (\(counter))" : "\(filename) (\(counter)).\(ext)"
                    finalDestination = directory.appendingPathComponent(newName)
                    counter += 1
                } while fileManager.fileExists(atPath: finalDestination.path)
            }
        }
        
        try data.write(to: finalDestination)
        return finalDestination
    }
    
    // MARK: - Delete Object
    
    func deleteObject(key: String) async throws {
        guard settings.isConfigured else {
            throw S3Error(message: "S3 not configured")
        }
        
        let host = buildHost()
        let endpoint = buildEndpoint()
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(objectKey: key)
        
        guard let url = URL(string: "\(endpoint)/\(encodedKey)") else {
            throw S3Error(message: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        let headers = try signRequest(
            method: "DELETE",
            path: signingPath,
            query: "",
            headers: ["host": host],
            payload: Data()
        )
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }
        
        guard httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw S3Error(message: "Delete failed: \(httpResponse.statusCode) - \(body)")
        }
    }
    
    // MARK: - Private Methods
    
    private func putObject(
        key: String,
        data: Data,
        contentType: String,
        progress: ((Double) -> Void)?
    ) async throws {
        let host = buildHost()
        let endpoint = buildEndpoint()
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(objectKey: key)
        
        guard let url = URL(string: "\(endpoint)/\(encodedKey)") else {
            throw S3Error(message: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data

        // Build headers - skip ACL for private buckets
        var uploadHeaders: [String: String] = [
            "host": host,
            "content-type": contentType
        ]
        if !settings.isPrivateBucket {
            uploadHeaders["x-amz-acl"] = "public-read"
        }

        let headers = try signRequest(
            method: "PUT",
            path: signingPath,
            query: "",
            headers: uploadHeaders,
            payload: data
        )
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let progressDelegate = UploadProgressDelegate { sent, expected in
            guard expected > 0 else { return }
            progress?(min(1, Double(sent) / Double(expected)))
        }
        
        let (responseData, response) = try await URLSession.shared.upload(
            for: request,
            from: data,
            delegate: progressDelegate
        )
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw S3Error(message: "Upload failed: \(httpResponse.statusCode) - \(body)")
        }
        
        progress?(1)
    }
    
    private func isCustomEndpoint() -> Bool {
        return !settings.endpoint.isEmpty
    }
    
    private func buildHost() -> String {
        let bucket = settings.bucket
        let region = settings.region
        
        if isCustomEndpoint() {
            // Custom endpoint (like Cloudflare R2, MinIO, etc.)
            // R2 and most S3-compatible services use path-style, so host is just the endpoint host
            if let url = URL(string: settings.endpoint), let host = url.host {
                return host
            }
        }
        
        return "\(bucket).s3.\(region).amazonaws.com"
    }
    
    private func buildEndpoint() -> String {
        let bucket = settings.bucket
        let region = settings.region
        
        if isCustomEndpoint() {
            // Custom endpoint (R2, MinIO, etc.) - use path-style: endpoint/bucket
            let base = settings.endpoint.hasSuffix("/") ? String(settings.endpoint.dropLast()) : settings.endpoint
            return "\(base)/\(bucket)"
        }
        
        return "https://\(bucket).s3.\(region).amazonaws.com"
    }
    
    private func buildSigningPath(objectKey: String?) -> String {
        let bucket = settings.bucket
        
        if isCustomEndpoint() {
            // Path-style: /bucket or /bucket/key
            if let key = objectKey {
                let encodedKey = awsURLEncodePath(key)
                return "/\(bucket)/\(encodedKey)"
            }
            return "/\(bucket)/"
        }
        
        // Virtual-hosted style: / or /key
        if let key = objectKey {
            let encodedKey = awsURLEncodePath(key)
            return "/\(encodedKey)"
        }
        return "/"
    }
    
    private func buildPublicURL(key: String) -> String {
        // If private bucket, generate presigned URL
        if settings.isPrivateBucket {
            return generatePresignedURL(key: key, expiration: Int(settings.presignedUrlExpiration))
        }

        let encodedKey = awsURLEncodePath(key)

        if !settings.publicUrlBase.isEmpty {
            let base = settings.publicUrlBase.hasSuffix("/") ? String(settings.publicUrlBase.dropLast()) : settings.publicUrlBase
            return "\(base)/\(encodedKey)"
        }

        return "\(buildEndpoint())/\(encodedKey)"
    }

    // MARK: - Presigned URL Generation

    private func generatePresignedURL(key: String, expiration: Int) -> String {
        let accessKey = settings.accessKeyId
        let secretKey = settings.secretAccessKey
        let region = settings.region
        let service = "s3"

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = dateFormatter.string(from: now)

        let dateStampFormatter = DateFormatter()
        dateStampFormatter.dateFormat = "yyyyMMdd"
        dateStampFormatter.timeZone = TimeZone(identifier: "UTC")
        let dateStamp = dateStampFormatter.string(from: now)

        let host = buildHost()
        let endpoint = buildEndpoint()
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(objectKey: key)

        // Build credential scope
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let credential = "\(accessKey)/\(credentialScope)"

        // Build canonical query string (alphabetically sorted)
        let queryParams: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", credential),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", "\(expiration)"),
            ("X-Amz-SignedHeaders", "host")
        ]

        let canonicalQueryString = queryParams
            .map { "\(awsQueryEncode($0.0))=\(awsQueryEncode($0.1))" }
            .joined(separator: "&")

        // Build canonical headers
        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"

        // Build canonical request
        let canonicalRequest = [
            "GET",
            signingPath,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString

        // Build string to sign
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            canonicalRequestHash
        ].joined(separator: "\n")

        // Calculate signature
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).hexString

        // Build final URL
        let finalQueryString = "\(canonicalQueryString)&X-Amz-Signature=\(signature)"
        return "\(endpoint)/\(encodedKey)?\(finalQueryString)"
    }

    private func awsQueryEncode(_ string: String) -> String {
        // AWS requires specific encoding for query parameters
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
    
    // MARK: - AWS Signature V4
    
    private func signRequest(
        method: String,
        path: String,
        query: String,
        headers: [String: String],
        payload: Data
    ) throws -> [String: String] {
        let accessKey = settings.accessKeyId
        let secretKey = settings.secretAccessKey
        let region = settings.region
        let service = "s3"
        
        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        
        let amzDate = dateFormatter.string(from: now).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        let dateStamp = String(amzDate.prefix(8))
        
        // Create payload hash
        let payloadHash = SHA256.hash(data: payload).hexString
        
        // Build canonical headers
        var allHeaders = headers
        allHeaders["x-amz-date"] = amzDate
        allHeaders["x-amz-content-sha256"] = payloadHash
        
        let sortedHeaders = allHeaders.sorted { $0.key.lowercased() < $1.key.lowercased() }
        let canonicalHeaders = sortedHeaders.map { "\($0.key.lowercased()):\($0.value.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n") + "\n"
        let signedHeaders = sortedHeaders.map { $0.key.lowercased() }.joined(separator: ";")
        
        // Create canonical request
        let canonicalRequest = [
            method,
            path,
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        
        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString
        
        // Create string to sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            canonicalRequestHash
        ].joined(separator: "\n")
        
        // Calculate signature
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).hexString
        
        // Build authorization header
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        
        var result = allHeaders
        result["authorization"] = authorization
        
        return result
    }
    
    private func hmacSHA256(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(signature)
    }
    
    private func mimeType(for ext: String) -> String {
        let mimeTypes: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "webp": "image/webp",
            "svg": "image/svg+xml",
            "pdf": "application/pdf",
            "zip": "application/zip",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "mp3": "audio/mpeg",
            "txt": "text/plain",
            "html": "text/html",
            "css": "text/css",
            "js": "application/javascript",
            "json": "application/json"
        ]
        return mimeTypes[ext.lowercased()] ?? "application/octet-stream"
    }
    
    private func parseListResponse(_ data: Data) -> [S3Object] {
        // Simple XML parsing for S3 list response
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        
        var objects: [S3Object] = []
        let contents = xml.components(separatedBy: "<Contents>")
        
        for content in contents.dropFirst() {
            guard let keyEnd = content.range(of: "</Key>"),
                  let keyStart = content.range(of: "<Key>") else { continue }
            
            let key = String(content[keyStart.upperBound..<keyEnd.lowerBound])
            
            var size: Int64 = 0
            if let sizeStart = content.range(of: "<Size>"),
               let sizeEnd = content.range(of: "</Size>") {
                size = Int64(content[sizeStart.upperBound..<sizeEnd.lowerBound]) ?? 0
            }
            
            var lastModified: Date?
            if let dateStart = content.range(of: "<LastModified>"),
               let dateEnd = content.range(of: "</LastModified>") {
                let dateString = String(content[dateStart.upperBound..<dateEnd.lowerBound])
                lastModified = parseLastModified(dateString)
            }
            
            objects.append(S3Object(key: key, size: size, lastModified: lastModified ?? Date()))
        }
        
        return objects.sorted { $0.lastModified > $1.lastModified }
    }

    private func parseLastModified(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private func awsURLEncodePath(_ path: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return path
            .split(separator: "/")
            .map { segment in
                segment.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String(segment)
            }
            .joined(separator: "/")
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Int64, Int64) -> Void
    
    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Int64, Int64) -> Void
    
    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceiveInformationalResponse response: HTTPURLResponse
    ) {
        // Optional: handle informational responses
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        // Optional: handle metrics
    }
}

extension DownloadProgressDelegate: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Required by protocol but handled by async/await
    }
}

struct S3Object: Identifiable {
    let id = UUID()
    let key: String
    let size: Int64
    let lastModified: Date
    
    var filename: String {
        // Remove UUID prefix if present
        let components = key.components(separatedBy: "-")
        if components.count > 1 && components[0].count == 8 {
            return components.dropFirst().joined(separator: "-")
        }
        return key
    }
}

extension SHA256Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
