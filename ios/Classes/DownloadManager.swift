import AVFoundation
import Foundation

@objc public class DownloadManager: NSObject {
    /// Singleton for DownloadManager.
    @objc public static let sharedManager = DownloadManager()

    /// The AVAssetDownloadURLSession to use for managing AVAssetDownloadTasks.
    fileprivate var assetDownloadURLSession: AVAssetDownloadURLSession!

    /// Internal map of AVAggregateAssetDownloadTask to its corresponding DownloadItem.
    fileprivate var activeDownloadsMap = [AVAggregateAssetDownloadTask: DownloadItem]()

    fileprivate var pendingKeyDataMap = [String: PendingKeyData]()

    fileprivate let dataPrefix = "Data"

    fileprivate let bookmarkPrefix = "Bookmark"

    override private init() {
        super.init()

        let backgroundConfiguration = URLSessionConfiguration.background(
            withIdentifier: "betterplayer-download")

        assetDownloadURLSession =
            AVAssetDownloadURLSession(
                configuration: backgroundConfiguration,
                assetDownloadDelegate: self,
                delegateQueue: OperationQueue.main)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(
                handleContentKeyDelegateDidSavePersistableContentKey(notification:)),
            name: .DidSavePersistableContentKey, object: nil)
    }

    @objc public func download(
        _ url: URL,
        dataString: String,
        licenseUrl: URL?,
        certificateUrl: URL?,
        drmHeaders: [String: String],
        eventChannel: FlutterEventChannel,
        result: @escaping FlutterResult
    ) {
        let isInProgress =
            activeDownloadsMap.keys.contains { $0.urlAsset.url == url }
            || pendingKeyDataMap.values.contains { $0.asset.url == url }

        if isInProgress {
            result(nil)
            return
        }

        let urlAsset = AVURLAsset(url: url)

        if let licenseUrl = licenseUrl, let certificateUrl = certificateUrl {
            var kidMap = UserDefaults.standard.dictionary(forKey: "kid_map") ?? [String: String]()
            let kid = URLComponents(url: licenseUrl, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "kid" })?.value
            if let kid = kid {
                kidMap.updateValue(kid, forKey: url.absoluteString)
                UserDefaults.standard.setValue(kidMap, forKey: "kid_map")
            } else {
                print("Failed to find kid in licenseUrl: \(licenseUrl)")
                return
            }

            pendingKeyDataMap[licenseUrl.absoluteString] = PendingKeyData(
                asset: urlAsset, dataString: dataString,
                eventChannel: eventChannel, flutterResult: result)

            ContentKeyManager.shared.addRecipient(
                urlAsset, certificateUrl: certificateUrl.absoluteString,
                licenseUrl: licenseUrl.absoluteString, headers: drmHeaders)
            ContentKeyManager.shared.requestPersistableContentKeys(forUrl: licenseUrl)
        } else {
            download(urlAsset, dataString: dataString, eventChannel: eventChannel, result: result)
        }
    }

    private func download(
        _ urlAsset: AVURLAsset,
        dataString: String,
        eventChannel: FlutterEventChannel,
        result: FlutterResult
    ) {
        guard
            let task =
                assetDownloadURLSession.aggregateAssetDownloadTask(
                    with: urlAsset,
                    mediaSelections: [urlAsset.preferredMediaSelection],
                    assetTitle: "",
                    assetArtworkData: nil,
                    options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 265_000])
        else { return }

        let downloadItem = DownloadItem(urlAsset: urlAsset, downloadData: dataString)
        eventChannel.setStreamHandler(downloadItem)
        activeDownloadsMap[task] = downloadItem

        task.resume()
        result(nil)
    }

    /// Returns an AVURLAsset pointing to a file on disk if it exists.
    @objc public func localAsset(url: URL) -> AVURLAsset? {
        let userDefaults = UserDefaults.standard
        guard
            let localFileLocation = userDefaults.value(forKey: bookmarkPrefix + url.absoluteString)
                as? Data
        else { return nil }

        var bookmarkDataIsStale = false
        do {
            let localUrl = try URL(
                resolvingBookmarkData: localFileLocation,
                bookmarkDataIsStale: &bookmarkDataIsStale)

            if bookmarkDataIsStale {
                userDefaults.removeObject(forKey: bookmarkPrefix + url.absoluteString)
                userDefaults.removeObject(forKey: dataPrefix + url.absoluteString)
                fatalError("Bookmark data is stale!")
            }

            let urlAsset = AVURLAsset(url: localUrl)

            return urlAsset
        } catch {
            fatalError("Failed to create URL from bookmark with error: \(error)")
        }
    }

    @objc public func downloadedAssets() -> [String: String] {
        let userDefaults = UserDefaults.standard
        let downloads =
            userDefaults.dictionaryRepresentation().filter { $0.key.hasPrefix(dataPrefix) }
            as! [String: String]

        return [String: String](
            uniqueKeysWithValues: downloads.map { key, value in
                (String(key.suffix(from: key.index(key.startIndex, offsetBy: 4))), value)
            })
    }

    /// Deletes an Asset on disk if possible.
    @objc public func deleteAsset(_ url: URL) {
        let userDefaults = UserDefaults.standard

        do {
            if let localFileLocation = localAsset(url: url)?.url {
                try FileManager.default.removeItem(at: localFileLocation)
            }
        } catch {
            print("An error occured deleting the file: \(error)")
        }
        userDefaults.removeObject(forKey: bookmarkPrefix + url.absoluteString)
        userDefaults.removeObject(forKey: dataPrefix + url.absoluteString)
    }

    @objc
    func handleContentKeyDelegateDidSavePersistableContentKey(notification: Notification) {
        // This handle can be called from different threads. NotificationCenter runs callbacks in the thread that posted the notification.
        // Thus we move excecution to the main thread to avoid data races.

        DispatchQueue.main.async {
            guard
                let url = notification.userInfo?["url"] as? URL,
                let pendingKeyData = self.pendingKeyDataMap.removeValue(forKey: url.absoluteString)
            else {
                print("error while retrieving pending download values")
                return
            }

            self.download(
                pendingKeyData.asset,
                dataString: pendingKeyData.dataString,
                eventChannel: pendingKeyData.eventChannel,
                result: pendingKeyData.flutterResult)
        }
    }
}

extension DownloadManager: AVAssetDownloadDelegate {
    /// Tells the delegate that the task finished transferring data.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        let downloadItem = activeDownloadsMap.removeValue(
            forKey: task as! AVAggregateAssetDownloadTask)

        if error == nil {
            downloadItem?.eventSink?(100.0)
        }
        downloadItem?.eventSink?(FlutterEndOfEventStream)

        let userDefaults = UserDefaults.standard
        let localURL = downloadItem?.localUrl

        if error != nil {
            if let localURL = localURL {
                do {
                    try FileManager.default.removeItem(at: localURL)
                } catch {
                    print("An error occured trying to delete the contents on disk for: \(error)")
                }
            }

            if let urlString = downloadItem?.urlAsset.url.absoluteString {
                userDefaults.removeObject(forKey: bookmarkPrefix + urlString)
                userDefaults.removeObject(forKey: dataPrefix + urlString)
            }
        } else {
            do {
                let bookmark = try localURL?.bookmarkData()
                let urlString = downloadItem?.urlAsset.url.absoluteString

                if let bookmark = bookmark, let urlString = urlString {
                    userDefaults.set(bookmark, forKey: bookmarkPrefix + urlString)
                    userDefaults.set(downloadItem?.downloadData, forKey: dataPrefix + urlString)
                } else {
                    print("Failed to create bookmarkData for download URL.")
                }
            } catch {
                print("Failed to create bookmarkData for download URL.")
            }
        }
    }

    /// Method called when the an aggregate download task determines the location this asset will be downloaded to.
    public func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        activeDownloadsMap[aggregateAssetDownloadTask]?.localUrl = location
    }

    /// Method to adopt to subscribe to progress updates of an AVAggregateAssetDownloadTask.
    public func urlSession(
        _ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection
    ) {
        var percentComplete = 0.0
        for value in loadedTimeRanges {
            let loadedTimeRange = value.timeRangeValue
            percentComplete +=
                loadedTimeRange.duration.seconds / timeRangeExpectedToLoad.duration.seconds
        }

        if let streamHandler = activeDownloadsMap[aggregateAssetDownloadTask] {
            streamHandler.eventSink?(percentComplete * 100)
        }
    }
}

private struct PendingKeyData {
    public let asset: AVURLAsset
    public let dataString: String
    public let eventChannel: FlutterEventChannel
    public let flutterResult: FlutterResult
}
