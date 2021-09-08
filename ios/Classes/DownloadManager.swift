import Foundation
import AVFoundation

@objc public class DownloadManager: NSObject {
    
    /// Singleton for DownloadManager.
    @objc public static let sharedManager = DownloadManager()
    
    /// The AVAssetDownloadURLSession to use for managing AVAssetDownloadTasks.
    fileprivate var assetDownloadURLSession: AVAssetDownloadURLSession!
    
    /// Internal map of AVAggregateAssetDownloadTask to its corresponding DownloadItem.
    fileprivate var activeDownloadsMap = [AVAggregateAssetDownloadTask: DownloadItem]()
    
    fileprivate let dataPrefix = "Data"
    
    fileprivate let bookmarkPrefix = "Bookmark"
    
    override private init() {
        
        super.init()
        
        let backgroundConfiguration = URLSessionConfiguration.background(withIdentifier: "betterplayer-download")
        
        assetDownloadURLSession =
            AVAssetDownloadURLSession(configuration: backgroundConfiguration,
                                      assetDownloadDelegate: self, delegateQueue: OperationQueue.main)
        
    }
    
    @objc public func download(_ url: URL, dataString: String, eventChannel: FlutterEventChannel, completionHandler: ((_ success:Bool) -> Void)?) {
        if (activeDownloadsMap.keys.contains { key in
            if (key.urlAsset.url == url) {
                return true
            } else {
                return false
            }
        }) {
            // download for this url is already in progress
            completionHandler?(true)
            return
        }
        
        let urlAsset = AVURLAsset(url: url)
        
        guard let task =
                assetDownloadURLSession.aggregateAssetDownloadTask(with: urlAsset,
                                                                   mediaSelections: [urlAsset.preferredMediaSelection],
                                                                   assetTitle: "",
                                                                   assetArtworkData: nil,
                                                                   options:
                                                                    [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 265_000]) else { return }
        
        let downloadItem = DownloadItem(urlAsset: urlAsset, downloadData: dataString)
        eventChannel.setStreamHandler(downloadItem)
        activeDownloadsMap[task] = downloadItem
        
        task.resume()
        completionHandler?(true)
        
    }
    
    /// Returns an AVURLAsset pointing to a file on disk if it exists.
    @objc public func localAsset(url: URL) -> AVURLAsset? {
        let userDefaults = UserDefaults.standard
        guard let localFileLocation = userDefaults.value(forKey: bookmarkPrefix + url.absoluteString) as? Data else { return nil }
        
        var bookmarkDataIsStale = false
        do {
            let localUrl = try URL(resolvingBookmarkData: localFileLocation,
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
    
    @objc public func downloadedAssets() -> Dictionary<String,String> {
        let userDefaults = UserDefaults.standard
        let downloads = userDefaults.dictionaryRepresentation().filter { (key, _) -> Bool in
            key.hasPrefix(dataPrefix)
        } as! [String: String]
        
        return Dictionary<String,String>(uniqueKeysWithValues: downloads.map
        { key, value in (String(key.suffix(from: key.index(key.startIndex, offsetBy: 4))), value) })
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
    
}

extension DownloadManager: AVAssetDownloadDelegate {
    
    /// Tells the delegate that the task finished transferring data.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        
        let downloadItem = activeDownloadsMap.removeValue(forKey: task as! AVAggregateAssetDownloadTask)
        
        if (error == nil) {
            downloadItem?.eventSink?(100.0)
        }
        downloadItem?.eventSink?(FlutterEndOfEventStream)
        
        let userDefaults = UserDefaults.standard
        let localURL = downloadItem?.localUrl
        
        if let error = error as NSError? {
            if (error.code == NSURLErrorCancelled) {
                do {
                    try FileManager.default.removeItem(at: localURL!)
                    if let urlString = downloadItem?.urlAsset.url.absoluteString {
                        userDefaults.removeObject(forKey: bookmarkPrefix + urlString)
                        userDefaults.removeObject(forKey: dataPrefix + urlString)
                    }
                } catch {
                    print("An error occured trying to delete the contents on disk for: \(error)")
                }
            }
        } else {
            do {
                let bookmark = try localURL!.bookmarkData()
                let urlString = (downloadItem?.urlAsset.url.absoluteString)!
                
                userDefaults.set(bookmark, forKey: bookmarkPrefix + urlString)
                userDefaults.set(downloadItem?.downloadData, forKey: dataPrefix + urlString)
            } catch {
                print("Failed to create bookmarkData for download URL.")
            }
        }
    }
    
    /// Method called when the an aggregate download task determines the location this asset will be downloaded to.
    public func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
                           willDownloadTo location: URL) {
        
        activeDownloadsMap[aggregateAssetDownloadTask]?.localUrl = location
    }
    
    /// Method to adopt to subscribe to progress updates of an AVAggregateAssetDownloadTask.
    public func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
                           didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                           timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection) {
        
        var percentComplete = 0.0
        for value in loadedTimeRanges {
            let loadedTimeRange: CMTimeRange = value.timeRangeValue
            percentComplete +=
                loadedTimeRange.duration.seconds / timeRangeExpectedToLoad.duration.seconds
        }
        
        if let streamHandler = activeDownloadsMap[aggregateAssetDownloadTask] {
            streamHandler.eventSink?(percentComplete * 100)
        }
    }
}
