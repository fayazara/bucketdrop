//
//  ContentView.swift
//  BucketDrop
//
//  Created by Fayaz Ahmed Aralikatti on 12/01/26.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine
import AppKit
import Quartz

// Model to track individual file upload state
struct UploadTask: Identifiable {
    let id = UUID()
    let filename: String
    let url: URL
    var progress: Double = 0
    var status: UploadStatus = .pending
    var resultURL: String?
    
    enum UploadStatus {
        case pending
        case uploading
        case completed
        case failed(String)
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettingsAction) private var openSettings
    @Query(sort: \UploadedFile.uploadedAt, order: .reverse) private var uploadedFiles: [UploadedFile]
    
    var settings = SettingsManager.shared
    
    @State private var isTargeted = false
    @State private var isUploading = false
    @State private var uploadTasks: [UploadTask] = []
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var s3Objects: [S3Object] = []
    @State private var isLoadingList = false
    
    // Download/Preview state
    @State private var downloadingObjectKey: String?
    @State private var downloadProgress: Double = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("BucketDrop")
                    .font(.headline)
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            if !settings.isConfigured {
                // Not configured view
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("R2/S3 Not Configured")
                        .font(.headline)
                    Text("Add your R2/S3 credentials in settings to start uploading.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        openSettings()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                // Drop zone
                DropZoneView(
                    isTargeted: $isTargeted,
                    isUploading: isUploading,
                    uploadTasks: uploadTasks
                )
                .onTapGesture {
                    if !isUploading {
                        openFilePicker()
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    guard !isUploading else { return false }
                    NSApp.activate(ignoringOtherApps: true)
                    handleDrop(providers)
                    return true
                }
                .padding(16)
                
                // Error message
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button {
                            errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                
                // Divider()
                
                // Recent uploads
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Recent Uploads")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isLoadingList {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                Task { await loadS3Objects() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    
                    if s3Objects.isEmpty && !isLoadingList {
                        VStack {
                            Text("No files yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            List {
                                ForEach(s3Objects) { object in
                                    FileRowView(
                                        object: object,
                                        previewURL: previewURL(for: object),
                                        isDownloading: downloadingObjectKey == object.key,
                                        downloadProgress: downloadingObjectKey == object.key ? downloadProgress : 0
                                    ) {
                                        copyToClipboard(object)
                                    } onDelete: {
                                        await deleteObject(object)
                                    } onDownload: {
                                        await downloadToDownloads(object)
                                    } onPreview: {
                                        previewFile(object)
                                    }
                                    .id(object.id)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                }
                            }
                            .listStyle(.plain)
                            .scrollIndicators(.never)
                            .onChange(of: s3Objects.first?.id) { _, newValue in
                                guard let newValue else { return }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(newValue, anchor: .top)
                                }
                            }
                        }
                    }
                }
            }
        }
        // .background(Color(nsColor: .textBackgroundColor)) // enable this for bg color
        .frame(width: 320, height: 460)
        .task {
            if settings.isConfigured {
                await loadS3Objects()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .filesDroppedOnStatusBar)) { notification in
            guard let urls = notification.userInfo?["urls"] as? [URL], !urls.isEmpty else { return }
            guard settings.isConfigured && !isUploading else { return }
            Task { @MainActor in
                await uploadFiles(urls)
            }
        }
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) {
        // Collect all file URLs first, then process as a batch
        let lock = NSLock()
        var collectedURLs: [URL] = []
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, error in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                collectedURLs.append(url)
                lock.unlock()
            }
        }
        
        group.notify(queue: .main) {
            Task { @MainActor in
                await self.uploadFiles(collectedURLs)
            }
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else { return }
                Task { @MainActor in
                    await uploadFiles(panel.urls)
                }
            }
        } else {
            let response = panel.runModal()
            guard response == .OK else { return }
            Task { @MainActor in
                await uploadFiles(panel.urls)
            }
        }
    }
    
    @MainActor
    private func uploadFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        
        // Create upload tasks for all files
        uploadTasks = urls.map { UploadTask(filename: $0.lastPathComponent, url: $0) }
        isUploading = true
        errorMessage = nil
        
        var uploadedURLs: [String] = []
        
        // Upload files sequentially for clearer progress indication
        for index in uploadTasks.indices {
            uploadTasks[index].status = .uploading
            
            do {
                let fileURL = uploadTasks[index].url
                let result = try await S3Service.shared.upload(fileURL: fileURL) { progress in
                    Task { @MainActor in
                        if index < self.uploadTasks.count {
                            self.uploadTasks[index].progress = progress
                        }
                    }
                }
                
                // Save to local storage
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                let uploadedFile = UploadedFile(
                    filename: fileURL.lastPathComponent,
                    key: result.key,
                    url: result.url,
                    size: fileSize
                )
                modelContext.insert(uploadedFile)
                
                uploadTasks[index].status = .completed
                uploadTasks[index].progress = 1
                uploadTasks[index].resultURL = result.url
                uploadedURLs.append(result.url)
                
                // Add to list immediately
                let newObject = S3Object(key: result.key, size: fileSize, lastModified: Date())
                s3Objects.insert(newObject, at: 0)
                
            } catch {
                uploadTasks[index].status = .failed(error.localizedDescription)
                errorMessage = "Some uploads failed"
            }
        }
        
        // Copy all successful URLs to clipboard
        if !uploadedURLs.isEmpty {
            NSPasteboard.general.clearContents()
            if uploadedURLs.count == 1 {
                NSPasteboard.general.setString(uploadedURLs[0], forType: .string)
            } else {
                // Join multiple URLs with newlines
                NSPasteboard.general.setString(uploadedURLs.joined(separator: "\n"), forType: .string)
            }
        }
        
        // Reset after delay
        try? await Task.sleep(for: .seconds(2))
        uploadTasks = []
        isUploading = false
    }
    
    private func loadS3Objects() async {
        isLoadingList = true
        do {
            s3Objects = try await S3Service.shared.listObjects()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingList = false
    }
    
    private func copyToClipboard(_ object: S3Object) {
        Task {
            let url = await S3Service.shared.getObjectURL(key: object.key)
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
    }

    private func buildURL(for object: S3Object) -> String {
        // For synchronous contexts like preview URLs, use public URL format
        let encodedKey = awsURLEncodePath(object.key)
        if !settings.publicUrlBase.isEmpty {
            let base = settings.publicUrlBase.hasSuffix("/") ? String(settings.publicUrlBase.dropLast()) : settings.publicUrlBase
            return "\(base)/\(encodedKey)"
        }
        return "https://\(settings.bucket).s3.\(settings.region).amazonaws.com/\(encodedKey)"
    }

    private func previewURL(for object: S3Object) -> URL? {
        guard isImageFile(object.filename) else { return nil }
        return URL(string: buildURL(for: object))
    }

    private func isImageFile(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "svg"].contains(ext)
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
    
    private func deleteObject(_ object: S3Object) async {
        do {
            try await S3Service.shared.deleteObject(key: object.key)
            await loadS3Objects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Cache
    
    private func cachedFileURL(for object: S3Object) -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("BucketDrop")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir.appendingPathComponent(object.key)
    }
    
    private func getCachedFile(for object: S3Object) -> URL? {
        let cachedURL = cachedFileURL(for: object)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        return nil
    }
    
    // MARK: - Download
    
    private func downloadToDownloads(_ object: S3Object) async {
        // Show save panel first
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = object.filename
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        
        NSApp.activate(ignoringOtherApps: true)
        let response = await savePanel.begin()
        
        guard response == .OK, let destination = savePanel.url else {
            return
        }
        
        // Check if we have it cached (from Quick Look preview)
        if let cachedURL = getCachedFile(for: object) {
            do {
                try FileManager.default.copyItem(at: cachedURL, to: destination)
                NSWorkspace.shared.selectFile(destination.path, inFileViewerRootedAtPath: "")
                return
            } catch {
                // Cache copy failed, fall through to download
            }
        }
        
        // Download from S3
        do {
            downloadingObjectKey = object.key
            downloadProgress = 0
            
            // Download to cache first, then copy to destination
            let cacheURL = cachedFileURL(for: object)
            let savedURL = try await S3Service.shared.download(key: object.key, to: cacheURL, overwrite: true) { progress in
                Task { @MainActor in
                    downloadProgress = progress
                }
            }
            
            // Copy from cache to user's destination
            try FileManager.default.copyItem(at: savedURL, to: destination)
            
            downloadingObjectKey = nil
            
            // Reveal in Finder
            NSWorkspace.shared.selectFile(destination.path, inFileViewerRootedAtPath: "")
        } catch {
            downloadingObjectKey = nil
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Preview with Quick Look
    
    private func previewFile(_ object: S3Object) {
        Task {
            let tempFile = cachedFileURL(for: object)
            
            // Check if already cached
            if let cachedURL = getCachedFile(for: object) {
                await MainActor.run {
                    showQuickLook(for: cachedURL)
                }
                return
            }
            
            // Download to cache
            do {
                downloadingObjectKey = object.key
                downloadProgress = 0
                
                let savedURL = try await S3Service.shared.download(key: object.key, to: tempFile, overwrite: true) { progress in
                    Task { @MainActor in
                        downloadProgress = progress
                    }
                }
                
                downloadingObjectKey = nil
                
                await MainActor.run {
                    showQuickLook(for: savedURL)
                }
            } catch {
                downloadingObjectKey = nil
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func showQuickLook(for url: URL) {
        // Use QLPreviewPanel for Quick Look
        let coordinator = QuickLookCoordinator()
        coordinator.items = [QuickLookItem(url: url)]
        
        // Store coordinator to keep it alive
        Self.quickLookCoordinator = coordinator
        
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = coordinator
        panel.delegate = coordinator
        panel.currentPreviewItemIndex = 0
        
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    // Static storage for coordinator
    private static var quickLookCoordinator: QuickLookCoordinator?
}

struct DropZoneView: View {
    @Binding var isTargeted: Bool
    let isUploading: Bool
    let uploadTasks: [UploadTask]
    
    private var completedCount: Int {
        uploadTasks.filter { 
            if case .completed = $0.status { return true }
            return false
        }.count
    }
    
    private var totalCount: Int {
        uploadTasks.count
    }
    
    private var overallProgress: Double {
        guard !uploadTasks.isEmpty else { return 0 }
        return uploadTasks.reduce(0) { $0 + $1.progress } / Double(uploadTasks.count)
    }
    
    private var currentlyUploading: UploadTask? {
        uploadTasks.first { 
            if case .uploading = $0.status { return true }
            return false
        }
    }
    
    private var allCompleted: Bool {
        completedCount == totalCount && totalCount > 0
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if isUploading {
                if allCompleted {
                    // All done state
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    if totalCount == 1 {
                        Text("Copied to clipboard!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(totalCount) URLs copied to clipboard!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Progress state
                    VStack(spacing: 6) {
                        ProgressView(value: overallProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 220)
                        
                        // Status text
                        if totalCount == 1 {
                            Text("Uploading \(currentlyUploading?.filename ?? "")...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("Uploading \(completedCount + 1) of \(totalCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let current = currentlyUploading {
                                Text(current.filename)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.up.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text(isTargeted ? "Drop to upload" : "Drop files here or click to select")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isTargeted ? 2 : 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}

// Custom progress style that doesn't gray out when window loses focus
struct ActiveProgressViewStyle: ProgressViewStyle {
    var height: CGFloat = 12
    
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            let progress = configuration.fractionCompleted ?? 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * progress)
                    .animation(.easeOut(duration: 0.15), value: progress)
            }
        }
        .frame(height: height)
    }
}

enum CachedImageState {
    case loading
    case success(Image)
    case failure
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    
    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }
    
    func insert(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

final class ImageLoader: ObservableObject {
    @Published var state: CachedImageState = .loading
    private var task: Task<Void, Never>?
    
    func load(from url: URL) {
        if let cached = ImageCache.shared.image(for: url) {
            state = .success(Image(nsImage: cached))
            return
        }
        
        task?.cancel()
        task = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data) else {
                    await MainActor.run { self.state = .failure }
                    return
                }
                ImageCache.shared.insert(image, for: url)
                await MainActor.run { self.state = .success(Image(nsImage: image)) }
            } catch {
                await MainActor.run { self.state = .failure }
            }
        }
    }
    
    func cancel() {
        task?.cancel()
        task = nil
    }
}

struct CachedAsyncImage<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (CachedImageState) -> Content
    @StateObject private var loader = ImageLoader()
    
    var body: some View {
        content(loader.state)
            .onAppear { loader.load(from: url) }
            .onChange(of: url) { _, newURL in
                loader.load(from: newURL)
            }
            .onDisappear { loader.cancel() }
    }
}

struct FileRowView: View {
    let object: S3Object
    let previewURL: URL?
    let isDownloading: Bool
    let downloadProgress: Double
    let onCopy: () -> Void
    let onDelete: () async -> Void
    let onDownload: () async -> Void
    let onPreview: () -> Void
    
    @State private var isHovered = false
    @State private var isDeleting = false
    @State private var isCopied = false
    
    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            if let previewURL {
                CachedAsyncImage(url: previewURL) { state in
                    switch state {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    Image(systemName: iconForFile(object.filename))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
            }
            
            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(object.filename)
                    .font(.system(.subheadline).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                // Show progress bar OR file size
                if isDownloading {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(ActiveProgressViewStyle(height: 6))
                        .padding(.top, 2)
                } else {
                    Text(formatSize(object.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer(minLength: 8)
            
            // Action buttons - always in layout, opacity controlled by hover
            HStack(spacing: 4) {
                Button {
                    if !isDeleting && !isDownloading {
                        onCopy()
                        Task { @MainActor in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isCopied = true
                            }
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isCopied = false
                            }
                        }
                    }
                } label: {
                    Image(systemName: isCopied ? "checkmark.circle.fill" : "link")
                        .foregroundStyle(isCopied ? Color.green : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy URL")
                .disabled(isDeleting || isDownloading)
                
                Button {
                    Task {
                        await onDownload()
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Download")
                .disabled(isDeleting || isDownloading)
                
                Button {
                    Task {
                        isDeleting = true
                        await onDelete()
                        isDeleting = false
                    }
                } label: {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                }
                .buttonStyle(.borderless)
                .help("Delete")
                .disabled(isDeleting || isDownloading)
            }
            .opacity(isHovered || isDeleting || isDownloading ? 1 : 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if !isDownloading {
                onPreview()
            }
        }
    }
    
    private func iconForFile(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "svg":
            return "photo"
        case "mp4", "mov", "avi":
            return "video"
        case "mp3", "wav", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "rar", "7z":
            return "archivebox"
        default:
            return "doc"
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Quick Look Support

class QuickLookItem: NSObject, QLPreviewItem {
    let url: URL
    
    init(url: URL) {
        self.url = url
        super.init()
    }
    
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { url.lastPathComponent }
}

class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [QuickLookItem] = []
    
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index < items.count else { return nil }
        return items[index]
    }
}

#Preview {
    ContentView()
        .modelContainer(for: UploadedFile.self, inMemory: true)
}
