//
//  SettingsView.swift
//  BucketDrop
//
//  Created by Fayaz Ahmed Aralikatti on 12/01/26.
//

import SwiftUI

struct SettingsView: View {
    var settings = SettingsManager.shared
    
    @State private var accessKeyId: String = ""
    @State private var secretAccessKey: String = ""
    @State private var bucket: String = ""
    @State private var region: String = ""
    @State private var endpoint: String = ""
    @State private var publicUrlBase: String = ""
    @State private var isPrivateBucket: Bool = false
    @State private var presignedUrlExpiration: TimeInterval = 3600

    @State private var isTesting = false
    @State private var testResult: TestResult?
    
    enum TestResult {
        case success
        case failure(String)
    }
    
    var body: some View {
        Form {
            Section {
                SecureField("Access Key ID", text: $accessKeyId)
                SecureField("Secret Access Key", text: $secretAccessKey)
                TextField("Bucket Name", text: $bucket)
                TextField("Region", text: $region, prompt: Text("us-east-1"))
            } header: {
                Text("S3 Credentials")
            }
            
            Section {
                TextField("S3 Endpoint", text: $endpoint, prompt: Text("https://xxx.r2.cloudflarestorage.com"))
                TextField("Public URL Base", text: $publicUrlBase, prompt: Text("https://static.example.com"))
            } header: {
                Text("S3-Compatible (R2, MinIO, etc.)")
            } footer: {
                Text("For Cloudflare R2: paste the S3 API endpoint URL and set region to 'auto'. Public URL Base is your custom domain for accessing files.")
            }

            Section {
                Toggle("Private bucket", isOn: $isPrivateBucket)

                if isPrivateBucket {
                    Picker("Link expiration", selection: $presignedUrlExpiration) {
                        Text("1 hour").tag(TimeInterval(3600))
                        Text("1 day").tag(TimeInterval(86400))
                        Text("7 days").tag(TimeInterval(604800))
                        Text("1 year").tag(TimeInterval(31536000))
                    }
                }
            } header: {
                Text("URL Settings")
            } footer: {
                Text(isPrivateBucket
                    ? "Files will be private. Copied links will be presigned and expire after the selected time."
                    : "Files will be publicly accessible via direct URL.")
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(isTesting || accessKeyId.isEmpty || secretAccessKey.isEmpty || bucket.isEmpty)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let result = testResult {
                        switch result {
                        case .success:
                            Label("Connected!", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let error):
                            Label(error, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }

                HStack {
                    Button("Quit") {
                        NSApp.terminate(nil)
                    }

                    Spacer()

                    Button("Save") {
                        saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accessKeyId.isEmpty || secretAccessKey.isEmpty || bucket.isEmpty)
                }
            }

            Section {
                HStack {
                    AsyncImage(url: URL(string: "https://github.com/fayazara.png")) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    }                     placeholder: {
                        Circle()
                            .fill(Color(nsColor: .quaternaryLabelColor))
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fayaz Ahmed")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Link("@fayazara", destination: URL(string: "https://x.com/fayazara")!)
                            .font(.caption)
                    }

                    Spacer()
                }

                HStack {
                    Spacer()
                    Text("Made in India")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loadSettings()
        }
    }
    
    private func loadSettings() {
        accessKeyId = settings.accessKeyId
        secretAccessKey = settings.secretAccessKey
        bucket = settings.bucket
        region = settings.region
        endpoint = settings.endpoint
        publicUrlBase = settings.publicUrlBase
        isPrivateBucket = settings.isPrivateBucket
        presignedUrlExpiration = settings.presignedUrlExpiration
    }
    
    private func saveSettings() {
        settings.accessKeyId = accessKeyId
        settings.secretAccessKey = secretAccessKey
        settings.bucket = bucket
        settings.region = region.isEmpty ? "us-east-1" : region
        settings.endpoint = endpoint
        settings.publicUrlBase = publicUrlBase
        settings.isPrivateBucket = isPrivateBucket
        settings.presignedUrlExpiration = presignedUrlExpiration

        testResult = .success

        // Close settings window after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.keyWindow?.close()
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        // Temporarily save settings for testing
        let oldAccessKey = settings.accessKeyId
        let oldSecretKey = settings.secretAccessKey
        let oldBucket = settings.bucket
        let oldRegion = settings.region
        let oldEndpoint = settings.endpoint
        
        settings.accessKeyId = accessKeyId
        settings.secretAccessKey = secretAccessKey
        settings.bucket = bucket
        settings.region = region.isEmpty ? "us-east-1" : region
        settings.endpoint = endpoint
        
        Task {
            do {
                _ = try await S3Service.shared.listObjects()
                await MainActor.run {
                    testResult = .success
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    // Restore old settings on failure
                    settings.accessKeyId = oldAccessKey
                    settings.secretAccessKey = oldSecretKey
                    settings.bucket = oldBucket
                    settings.region = oldRegion
                    settings.endpoint = oldEndpoint
                    
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
