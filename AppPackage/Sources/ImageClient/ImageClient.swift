import AnimatedImageFeature
import AppModels
public import AppTools
import ComposableArchitecture
public import Dependencies
public import Photos
public import SwiftUI

public struct ImageClient: Sendable {
    public struct ImageAsset: Sendable {
        public let image: UIImage
        public let data: Data

        /// Render / export routing for this asset: `true` → SDWebImage (animated),
        /// `false` → Kingfisher / `UIImage` (still). Decided from the actual bytes, not the
        /// request URL. See `Data.isAnimatedImageData`.
        public var isAnimated: Bool {
            data.isAnimatedImageData || image.hasAnimatedFrames
        }
    }

    /// Warms the reader's cache for `urls`, returning once every one of them is done. The work lives for as long as
    /// the awaiting caller does, so cancelling the caller (the reader closing) cancels the downloads under it.
    public let prefetchImages: @Sendable ([URL]) async -> Void
    public let saveImageDataToPhotoLibrary: @Sendable (Data) async -> Bool
    public var dataCache: DataCache
    public var urlSession: URLSession = .shared
}

extension ImageClient {
    public static var live: Self {
        @Dependency(\.dataCache) var injectedDataCache
        let dataCache = injectedDataCache
        return .init(
            prefetchImages: { urls in
                await Self.prefetch(urls: urls, dataCache: dataCache)
            },
            saveImageDataToPhotoLibrary: { data in
                await Self.saveImageDataToPhotoLibrary(data)
            },
            dataCache: dataCache
        )
    }

    /// How many pages one prefetch call downloads at the same time. A call that has nothing to download (every page is
    /// cached) finishes as fast as the cache answers; the cap only bounds the pages that are not cached yet.
    private static let prefetchWidth = 3

    @concurrent
    private static func prefetch(urls: [URL], dataCache: DataCache) async {
        await withTaskGroup(of: Void.self) { group in
            var remaining = urls.makeIterator()
            for _ in 0..<Self.prefetchWidth {
                guard let url = remaining.next() else { break }
                group.addTask {
                    await Self.prefetchOne(url: url, dataCache: dataCache)
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let url = remaining.next() else { continue }
                group.addTask {
                    await Self.prefetchOne(url: url, dataCache: dataCache)
                }
            }
        }
    }

    private static func prefetchOne(url: URL, dataCache: DataCache) async {
        do {
            _ = try await readerImageData(url: url, dataCache: dataCache, urlSession: .shared)
        } catch {
            // Prefetch failures are intentionally ignored: the foreground load retries.
        }
    }

    public static func saveImageDataToPhotoLibrary(_ data: Data) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            // The caller presents the existing save-failed notification.
            return false
        }
    }

    // Exports read the same owned bytes the reader display caches, so save/share/copy
    // route by image content (DES-1) instead of the request URL's extension.
    @concurrent
    public func fetchImageAsset(url: URL) async -> Result<ImageAsset, any Error> {
        await Result.Swift::init {
            let data = try await Self.readerImageData(
                url: url, dataCache: dataCache, urlSession: urlSession
            )
            guard let image = data.decodedImage else {
                throw AppError.parseFailed
            }
            return ImageAsset(image: image, data: data)
        }
    }

    @concurrent
    public func fetchReaderImageAsset(
        url: URL,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async -> ImageAsset? {
        do {
            let data = try await Self.readerImageData(
                url: url, dataCache: dataCache, urlSession: urlSession, onProgress: onProgress
            )
            guard let image = data.decodedImage else { return nil }
            return .init(image: image, data: data)
        } catch {
            // This optional reader API intentionally maps fetch or decode failure to no image asset.
            return nil
        }
    }

    @concurrent
    public static func readerImageData(
        url: URL,
        dataCache: DataCache,
        urlSession: URLSession,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        let cacheKeys = url.imageCacheKeys
        if let data = await dataCache.data(forKeys: cacheKeys) {
            // A known placeholder (limit/login wall) that was cached before this
            // guard existed must not be re-served; purge it and re-fetch so a
            // since-lifted limit recovers on its own.
            if ImagePlaceholderFingerprint.match(data) == nil {
                return data
            }
            do {
                try await dataCache.removeData(forKeys: cacheKeys)
            } catch {
                // Removing a stale placeholder is best-effort; the network refetch still proceeds.
            }
        }
        let downloadKey = "\(ObjectIdentifier(dataCache).hashValue)|\(url.absoluteString)"
        let data = try await ReaderImageDownloadCoordinator.shared.data(
            forKey: downloadKey, url: url, urlSession: urlSession, onProgress: onProgress
        )
        // E-H serves limit/login placeholders as valid 200 images; reject them as the
        // errors they are (matching the download pipeline) so they're never cached,
        // displayed, or exported as the real page.
        if let placeholder = ImagePlaceholderFingerprint.match(data) {
            throw placeholder.error
        }
        // Only cache decodable image bytes so a 200 carrying an HTML/error body
        // (e.g. an unexpected notice page) can't poison the key until expiry.
        guard data.decodedImage != nil else {
            throw AppError.parseFailed
        }
        // Store under the primary key only. Reads check the stable alias first and
        // it's non-nil for ~all page URLs, so also writing the absolute-URL alias
        // doubled disk + memory for an entry that retrieval never reaches.
        if let primaryKey = cacheKeys.first {
            do {
                try await dataCache.store(data, forKey: primaryKey)
            } catch {
                // Cache population is best-effort and must not turn a successful fetch into an error.
            }
        }
        return data
    }

    // Streams the body via `bytes(for:)` to drive per-image progress when a
    // handler is supplied; otherwise the single-shot `data(for:)` keeps the
    // progress-less prefetch path fast.
    @concurrent
    fileprivate static func downloadReaderData(
        url: URL,
        urlSession: URLSession,
        onProgress: (@Sendable (Double) async -> Void)?
    ) async throws -> Data {
        guard let onProgress else {
            let (data, response) = try await urlSession.data(for: URLRequest(url: url))
            try validateReaderResponse(response)
            return data
        }
        let (bytes, response) = try await urlSession.bytes(for: URLRequest(url: url))
        try validateReaderResponse(response)
        let expectedLength = response.expectedContentLength
        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        var lastReportedFraction = 0.0
        for try await byte in bytes {
            data.append(byte)
            guard expectedLength > 0 else { continue }
            let fraction = min(Double(data.count) / Double(expectedLength), 1)
            if fraction - lastReportedFraction >= 0.01 {
                lastReportedFraction = fraction
                await onProgress(fraction)
            }
        }
        return data
    }

    private static func validateReaderResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AppError.networkingFailed
        }
    }
}

// MARK: ReaderImageDownloadCoordinator
/// Shares one in-flight download between every caller that asks for the same page image.
///
/// The reader's foreground load, its prefetch and a prefetch started a page earlier all reach the same URL, and each
/// used to download it on its own, which cost bandwidth and the account's image limit. A caller that finds a download
/// under way joins it instead. Each caller is a waiter: when the last one is cancelled (the page scrolled away, the
/// reader closed) the download is cancelled with it, so a download nobody waits for never runs on.
///
/// Progress is reported to the waiters present while the download runs. It is only measured when the caller that starts
/// the download asks for it, so a prefetch keeps its single-shot request and a caller that joins it later shows no
/// progress until the page arrives.
private actor ReaderImageDownloadCoordinator {
    typealias ProgressHandler = @MainActor @Sendable (Double) -> Void

    private struct Entry {
        let id: UUID
        let task: Task<Data, any Error>
        var waiters: Set<UUID> = []
        var observers: [UUID: ProgressHandler] = [:]
    }

    static let shared = ReaderImageDownloadCoordinator()

    private var entries: [String: Entry] = [:]

    func data(
        forKey key: String,
        url: URL,
        urlSession: URLSession,
        onProgress: ProgressHandler?
    ) async throws -> Data {
        let waiterID = UUID()
        let task = join(key: key, url: url, urlSession: urlSession, waiterID: waiterID, onProgress: onProgress)
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            Task {
                await self.leave(key: key, waiterID: waiterID)
            }
        }
    }

    private func join(
        key: String,
        url: URL,
        urlSession: URLSession,
        waiterID: UUID,
        onProgress: ProgressHandler?
    ) -> Task<Data, any Error> {
        if var entry = entries[key] {
            entry.waiters.insert(waiterID)
            if let onProgress {
                entry.observers[waiterID] = onProgress
            }
            entries[key] = entry
            return entry.task
        }
        let id = UUID()
        let progressReport: (@Sendable (Double) async -> Void)?
        if onProgress != nil {
            progressReport = { fraction in
                await self.report(key: key, fraction: fraction)
            }
        } else {
            progressReport = nil
        }
        // The task runs on this actor, so it can only start once this call has registered the entry below.
        let task = Task<Data, any Error> {
            do {
                let data = try await ImageClient.downloadReaderData(
                    url: url,
                    urlSession: urlSession,
                    onProgress: progressReport
                )
                self.finish(key: key, id: id)
                return data
            } catch {
                self.finish(key: key, id: id)
                throw error
            }
        }
        var entry = Entry(id: id, task: task)
        entry.waiters.insert(waiterID)
        if let onProgress {
            entry.observers[waiterID] = onProgress
        }
        entries[key] = entry
        return task
    }

    private func report(key: String, fraction: Double) async {
        guard let entry = entries[key] else { return }
        let handlers = Array(entry.observers.values)
        for handler in handlers {
            await handler(fraction)
        }
    }

    private func finish(key: String, id: UUID) {
        guard entries[key]?.id == id else { return }
        entries[key] = nil
    }

    private func leave(key: String, waiterID: UUID) {
        guard var entry = entries[key] else { return }
        entry.waiters.remove(waiterID)
        entry.observers[waiterID] = nil
        if entry.waiters.isEmpty {
            entry.task.cancel()
            entries[key] = nil
        } else {
            entries[key] = entry
        }
    }
}

// MARK: API
public enum ImageClientKey: DependencyKey {
    public static let liveValue = ImageClient.live
    public static let previewValue = ImageClient.noop
    public static let testValue = ImageClient.unimplemented
}

extension DependencyValues {
    public var imageClient: ImageClient {
        get { self[ImageClientKey.self] }
        set { self[ImageClientKey.self] = newValue }
    }
}

// MARK: Test
extension ImageClient {
    public static var noop: Self {
        @Dependency(\.dataCache) var dataCache
        return .init(
            prefetchImages: { _ in },
            saveImageDataToPhotoLibrary: { _ in false },
            dataCache: dataCache
        )
    }

    public static func placeholder<Result>() -> Result { fatalError() }

    public static var unimplemented: Self {
        @Dependency(\.dataCache) var dataCache
        return .init(
            prefetchImages: IssueReporting.unimplemented(placeholder: placeholder()),
            saveImageDataToPhotoLibrary: IssueReporting.unimplemented(placeholder: placeholder()),
            dataCache: dataCache
        )
    }
}
