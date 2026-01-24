//
//  SettingsManager.swift
//  BucketDrop
//
//  Created by Fayaz Ahmed Aralikatti on 12/01/26.
//

import Foundation
import Security

@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard
    private let keychainService = Bundle.main.bundleIdentifier ?? "com.fayazahmed.BucketDrop"
    
    private enum Keys {
        static let accessKeyId = "s3_access_key_id"
        static let secretAccessKey = "s3_secret_access_key"
        static let bucket = "s3_bucket"
        static let region = "s3_region"
        static let endpoint = "s3_endpoint"
        static let publicUrlBase = "s3_public_url_base"
        static let isPrivateBucket = "s3_is_private_bucket"
        static let presignedUrlExpiration = "s3_presigned_url_expiration"
    }
    
    // Stored properties for observation
    private(set) var _accessKeyId: String = ""
    private(set) var _secretAccessKey: String = ""
    private(set) var _bucket: String = ""
    private(set) var _region: String = "us-east-1"
    private(set) var _endpoint: String = ""
    private(set) var _publicUrlBase: String = ""
    private(set) var _isPrivateBucket: Bool = false
    private(set) var _presignedUrlExpiration: TimeInterval = 3600 // 1 hour default
    
    var accessKeyId: String {
        get { _accessKeyId }
        set {
            _accessKeyId = newValue
            setKeychainItem(key: Keys.accessKeyId, value: newValue)
        }
    }
    
    var secretAccessKey: String {
        get { _secretAccessKey }
        set {
            _secretAccessKey = newValue
            setKeychainItem(key: Keys.secretAccessKey, value: newValue)
        }
    }
    
    var bucket: String {
        get { _bucket }
        set {
            _bucket = newValue
            defaults.set(newValue, forKey: Keys.bucket)
        }
    }
    
    var region: String {
        get { _region }
        set {
            _region = newValue
            defaults.set(newValue, forKey: Keys.region)
        }
    }
    
    var endpoint: String {
        get { _endpoint }
        set {
            _endpoint = newValue
            defaults.set(newValue, forKey: Keys.endpoint)
        }
    }
    
    var publicUrlBase: String {
        get { _publicUrlBase }
        set {
            _publicUrlBase = newValue
            defaults.set(newValue, forKey: Keys.publicUrlBase)
        }
    }

    var isPrivateBucket: Bool {
        get { _isPrivateBucket }
        set {
            _isPrivateBucket = newValue
            defaults.set(newValue, forKey: Keys.isPrivateBucket)
        }
    }

    var presignedUrlExpiration: TimeInterval {
        get { _presignedUrlExpiration }
        set {
            _presignedUrlExpiration = newValue
            defaults.set(newValue, forKey: Keys.presignedUrlExpiration)
        }
    }

    var isConfigured: Bool {
        !_accessKeyId.isEmpty && !_secretAccessKey.isEmpty && !_bucket.isEmpty
    }
    
    private init() {
        // Load initial values from storage
        _accessKeyId = getKeychainItem(key: Keys.accessKeyId) ?? ""
        _secretAccessKey = getKeychainItem(key: Keys.secretAccessKey) ?? ""
        _bucket = defaults.string(forKey: Keys.bucket) ?? ""
        _region = defaults.string(forKey: Keys.region) ?? "us-east-1"
        _endpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        _publicUrlBase = defaults.string(forKey: Keys.publicUrlBase) ?? ""
        _isPrivateBucket = defaults.bool(forKey: Keys.isPrivateBucket)
        _presignedUrlExpiration = defaults.double(forKey: Keys.presignedUrlExpiration)
        if _presignedUrlExpiration == 0 {
            _presignedUrlExpiration = 3600 // Default to 1 hour if not set
        }
    }
    
    // MARK: - Keychain
    
    private func setKeychainItem(key: String, value: String) {
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService
        ]
        
        SecItemDelete(query as CFDictionary)
        
        var newQuery = query
        newQuery[kSecValueData as String] = data
        SecItemAdd(newQuery as CFDictionary, nil)
    }
    
    private func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
}
