public class DownloadItem: NSObject, FlutterStreamHandler {
    public var eventSink: FlutterEventSink? = nil

    public let urlAsset: AVURLAsset

    public let downloadData: String

    public var localUrl: URL? = nil

    init(urlAsset: AVURLAsset, downloadData: String) {
        self.urlAsset = urlAsset
        self.downloadData = downloadData
    }

    public func onListen(
        withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
    )
        -> FlutterError?
    {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
