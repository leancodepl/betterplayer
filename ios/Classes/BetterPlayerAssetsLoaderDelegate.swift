import AVFoundation

@objc public class BetterPlayerAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    var jwtHeaderValue: String
    var certificateURL: URL
    var contentID: String
    
    @objc public init(licenseUrl: URL, certificateUrl: URL, headers: Dictionary<String, String>) {
        self.jwtHeaderValue = headers["Authorization"] ?? ""
        self.certificateURL = certificateUrl
        self.contentID = licenseUrl.host!
        super.init()
    }
    
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // We first check if a url is set in the manifest.
        guard let url = loadingRequest.request.url else {
            print("", #function, "Unable to read the url/host data.")
            loadingRequest.finishLoading(with: NSError(domain: "com.error", code: -1, userInfo: nil))
            return false
        }
        
        // get certificate data
        var certificateData: Data? = nil
        do {
            try certificateData = Data(contentsOf: certificateURL)
        } catch {
            print(#function, "Unable to read the certificate data.")
            loadingRequest.finishLoading(with: NSError(domain: "com.error", code: -2, userInfo: nil))
            return false
        }
        
        // Request the Server Playback Context
        guard
            let contentIdData = contentID.data(using: .utf8),
            let spcData = try? loadingRequest.streamingContentKeyRequestData(forApp: certificateData!, contentIdentifier: contentIdData, options: nil),
            let dataRequest = loadingRequest.dataRequest else {
                loadingRequest.finishLoading(with: NSError(domain: "com.error", code: -3, userInfo: nil))
                print(#function, "Unable to read the SPC data.")
                return false
        }
            
        // get CKC
        let ckcURLString = url.absoluteString.replacingOccurrences(of: "skd", with: "https")
        let ckcURL = URL(string: ckcURLString)!
        var request = URLRequest(url: ckcURL)
        request.httpMethod = "POST"
        let postString = "spc=\(spcData.base64EncodedString())&assetId=\(contentID)"
        request.setValue(String(postString.count), forHTTPHeaderField: "Content-Length")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(jwtHeaderValue, forHTTPHeaderField: "Authorization")
        request.httpBody = postString.data(using: .utf8)
        let session = URLSession(configuration: URLSessionConfiguration.default)
        let task = session.dataTask(with: request) { data, _, error in
            if let data = data {
                // The CKC is correctly returned and is now send to the `AVPlayer` instance so we
                // can continue to play the stream.
                if var responseString = String(data: data, encoding: .utf8) {
                    responseString = responseString.replacingOccurrences(of: "<ckc>", with: "").replacingOccurrences(of: "</ckc>", with: "")
                    let ckcData = Data(base64Encoded: responseString)!
                    dataRequest.respond(with: ckcData)
                    loadingRequest.finishLoading()
                }
                else{
                    print(#function, "Empty response")
                }

            } else {
                print(#function, "Unable to fetch the CKC.")
                loadingRequest.finishLoading(with: NSError(domain: "com.error", code: -4, userInfo: nil))
            }
        }
        task.resume()

        return true
    }
}

