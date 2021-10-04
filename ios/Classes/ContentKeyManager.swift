@objc public class ContentKeyManager: NSObject, AVContentKeySessionDelegate {
    
    /// The singleton for `ContentKeyManager`.
    @objc public static let shared: ContentKeyManager = ContentKeyManager()
    
    /// A set containing the currently pending content key identifiers associated with persistable content key requests that have not been completed.
    var pendingPersistableContentKeyIdentifiers = Set<String>()
    
    var certificatesMap = Dictionary<String, String>()
    var licensesMap = Dictionary<String, String>()
    var authHeadersMap = Dictionary<String, String>()
    
    @objc public let contentKeySession: AVContentKeySession
    let contentKeyDelegateQueue = DispatchQueue(label: "ContentKeyDelegateQueue")
    
    /// The directory that is used to save persistable content keys.
    lazy var contentKeyDirectory: URL = {
        guard let documentPath =
            NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else {
                fatalError("Unable to determine library URL")
        }
        
        let documentURL = URL(fileURLWithPath: documentPath)
        
        let contentKeyDirectory = documentURL.appendingPathComponent(".keys", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: contentKeyDirectory.path, isDirectory: nil) {
            do {
                try FileManager.default.createDirectory(at: contentKeyDirectory,
                                                    withIntermediateDirectories: false,
                                                    attributes: nil)
            } catch {
                fatalError("Unable to create directory for content keys at path: \(contentKeyDirectory.path)")
            }
        }
        
        return contentKeyDirectory
    }()
    
    private override init() {
        
        contentKeySession = AVContentKeySession(keySystem: .fairPlayStreaming)
        super.init()
        contentKeySession.setDelegate(self, queue: contentKeyDelegateQueue)
    }
    
    @objc public func addRecipient(_ asset: AVURLAsset, certificateUrl: String, licenseUrl: String, headers: Dictionary<String,String>) {
        contentKeySession.addContentKeyRecipient(asset)
        certificatesMap.updateValue(certificateUrl, forKey: licenseUrl)
        licensesMap.updateValue(licenseUrl.replacingOccurrences(of: "skd", with: "https"), forKey: licenseUrl)
        authHeadersMap.updateValue(headers["Authorization"] ?? "", forKey: licenseUrl)
    }
    
    public func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handleStreamingContentKeyRequest(keyRequest: keyRequest)
    }
    
    public func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest,
                                  reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        return false
    }
    
    public func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: Error) {
    }
    
    func handleStreamingContentKeyRequest(keyRequest: AVContentKeyRequest) {
        guard let contentKeyIdentifierString = keyRequest.identifier as? String,
        let contentKeyIdentifierURL = URL(string: contentKeyIdentifierString),
        let assetIDString = contentKeyIdentifierURL.host,
        let assetIDData = assetIDString.data(using: .utf8),
        let kid = URLComponents(string: contentKeyIdentifierString)?.queryItems?.first(where: {$0.name == "kid"})?.value
        else {
            print("Failed to retrieve the assetID from the keyRequest!")
            return
        }
        let provideOnlinekey: () -> Void = { () -> Void in
            do {
                let applicationCertificate = try self.requestApplicationCertificate(assetId: assetIDString, contentKeyIdentifier: contentKeyIdentifierString)

                let completionHandler = { [weak self] (spcData: Data?, error: Error?) in
                    guard let strongSelf = self else { return }
                    if let error = error {
                        keyRequest.processContentKeyResponseError(error)
                        return
                    }

                    guard let spcData = spcData else { return }

                    do {
                        // Send SPC to Key Server and obtain CKC
                        let ckcData = try strongSelf.requestContentKeyFromKeySecurityModule(spcData: spcData, assetID: assetIDString, contentKeyIdentifier: contentKeyIdentifierString)

                        /*
                         AVContentKeyResponse is used to represent the data returned from the key server when requesting a key for
                         decrypting content.
                         */
                        let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckcData)

                        /*
                         Provide the content key response to make protected content available for processing.
                         */
                        keyRequest.processContentKeyResponse(keyResponse)
                    } catch {
                        keyRequest.processContentKeyResponseError(error)
                    }
                }

                keyRequest.makeStreamingContentKeyRequestData(forApp: applicationCertificate,
                                                              contentIdentifier: assetIDData,
                                                              options: [AVContentKeyRequestProtocolVersionsKey: [1]],
                                                              completionHandler: completionHandler)
            } catch {
                keyRequest.processContentKeyResponseError(error)
            }
        }
        
        if (pendingPersistableContentKeyIdentifiers.contains(contentKeyIdentifierString) ||
                persistableContentKeyExistsOnDisk(withKid: kid)) {
            // Request a Persistable Key Request.
            do {
                try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
            } catch {

                /*
                This case will occur when the client gets a key loading request from an AirPlay Session.
                You should answer the key request using an online key from your key server.
                */
                provideOnlinekey()
            }
        } else {
            provideOnlinekey()
        }
    }
    
    func requestApplicationCertificate(assetId: String, contentKeyIdentifier: String) throws -> Data {
        // TODO: use proper urls
        var applicationCertificate: Data? = nil
        do {
            let certUrl = certificatesMap.removeValue(forKey: contentKeyIdentifier)
            applicationCertificate = try Data(contentsOf: URL(string: certUrl!)!)
        } catch {
            print("Error loading FairPlay application certificate: \(error)")
        }
        
        return applicationCertificate!
    }
    
    func requestContentKeyFromKeySecurityModule(spcData: Data, assetID: String, contentKeyIdentifier: String) throws -> Data {
        
        var ckcData: Data? = nil
            
            let semaphore = DispatchSemaphore(value: 0)
            let postString = "spc=\(spcData.base64EncodedString())&assetId=\(assetID)"
            if let postData = postString.data(using: .ascii, allowLossyConversion: true),
               let drmServerUrl = licensesMap.removeValue(forKey: contentKeyIdentifier)
                {
                var request = URLRequest(url: URL(string: drmServerUrl)!)
                request.httpMethod = "POST"
                request.setValue(String(postData.count), forHTTPHeaderField: "Content-Length")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.setValue(authHeadersMap.removeValue(forKey: contentKeyIdentifier), forHTTPHeaderField: "Authorization")
                request.httpBody = postData
                
                URLSession.shared.dataTask(with: request) { (data, _, error) in
                    if let data = data, var responseString = String(data: data, encoding: .utf8) {
                        responseString = responseString.replacingOccurrences(of: "<ckc>", with: "").replacingOccurrences(of: "</ckc>", with: "")
                        ckcData = Data(base64Encoded: responseString)
                    } else {
                        print("Error encountered while fetching FairPlay license:  \(error?.localizedDescription ?? "Unknown error")")
                    }
                    
                    semaphore.signal()
                    }.resume()
            } else {
                fatalError("Invalid post data")
            }
            
            semaphore.wait()
            return ckcData!
    }
    
    // MARK: PERSISTABLE
    
    public func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        handlePersistableContentKeyRequest(keyRequest: keyRequest)
    }
    
    public func contentKeySession(_ session: AVContentKeySession,
                           didUpdatePersistableContentKey persistableContentKey: Data,
                           forContentKeyIdentifier keyIdentifier: Any) {
        
        guard let contentKeyIdentifierString = keyIdentifier as? String,
            let kid = URLComponents(string: contentKeyIdentifierString)?.queryItems?.first(where: {$0.name == "kid"})?.value
            else {
                print("Failed to retrieve the assetID from the keyRequest!")
                return
        }
        
        do {
            deletePeristableContentKey(withKid: kid)
            try writePersistableContentKey(contentKey: persistableContentKey, withKid: kid)
        } catch {
            print("Failed to write updated persistable content key to disk: \(error.localizedDescription)")
        }
    }
    
    func handlePersistableContentKeyRequest(keyRequest: AVPersistableContentKeyRequest) {
        /*
         The key ID is the URI from the EXT-X-KEY tag in the playlist (e.g. "skd://key65") and the
         asset ID in this case is "key65".
         */
        guard let contentKeyIdentifierString = keyRequest.identifier as? String,
            let contentKeyIdentifierURL = URL(string: contentKeyIdentifierString),
            let assetIDString = contentKeyIdentifierURL.host,
            let assetIDData = assetIDString.data(using: .utf8),
            let kid = URLComponents(string: contentKeyIdentifierString)?.queryItems?.first(where: {$0.name == "kid"})?.value
            else {
                print("Failed to retrieve the assetID from the keyRequest!")
                return
        }
        
        do {

            let completionHandler = { [weak self] (spcData: Data?, error: Error?) in
                guard let strongSelf = self else { return }
                if let error = error {
                    keyRequest.processContentKeyResponseError(error)
                    
                    strongSelf.pendingPersistableContentKeyIdentifiers.remove(contentKeyIdentifierString)
                    return
                }
                
                guard let spcData = spcData else { return }
                
                do {
                    // Send SPC to Key Server and obtain CKC
                    let ckcData = try strongSelf.requestContentKeyFromKeySecurityModule(spcData: spcData, assetID: assetIDString, contentKeyIdentifier: contentKeyIdentifierString)
                    
                    let persistentKey = try keyRequest.persistableContentKey(fromKeyVendorResponse: ckcData, options: nil)
                    
                    try strongSelf.writePersistableContentKey(contentKey: persistentKey, withKid: kid)
                    
                    /*
                     AVContentKeyResponse is used to represent the data returned from the key server when requesting a key for
                     decrypting content.
                     */
                    let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistentKey)
                    
                    /*
                     Provide the content key response to make protected content available for processing.
                     */
                    keyRequest.processContentKeyResponse(keyResponse)
                    
                    NotificationCenter.default.post(name: .DidSavePersistableContentKey,
                                                    object: nil,
                                                    userInfo: ["url": contentKeyIdentifierURL])
                    
                    strongSelf.pendingPersistableContentKeyIdentifiers.remove(contentKeyIdentifierString)
                } catch {
                    keyRequest.processContentKeyResponseError(error)
                    
                    strongSelf.pendingPersistableContentKeyIdentifiers.remove(contentKeyIdentifierString)
                }
            }
            
            // Check to see if we can satisfy this key request using a saved persistent key file.
            if persistableContentKeyExistsOnDisk(withKid: kid) {
                
                let urlToPersistableKey = urlForPersistableContentKey(withKid: kid)
                
                guard let contentKey = FileManager.default.contents(atPath: urlToPersistableKey.path) else {
                    // Error Handling.
                    
                    pendingPersistableContentKeyIdentifiers.remove(contentKeyIdentifierString)
                    
                    /*
                     Key requests should never be left dangling.
                     Attempt to create a new persistable key.
                     */
                    let applicationCertificate = try requestApplicationCertificate(assetId: assetIDString, contentKeyIdentifier: contentKeyIdentifierString)
                    keyRequest.makeStreamingContentKeyRequestData(forApp: applicationCertificate,
                                                                  contentIdentifier: assetIDData,
                                                                  options: [AVContentKeyRequestProtocolVersionsKey: [1]],
                                                                  completionHandler: completionHandler)

                    return
                }
                
                /*
                 Create an AVContentKeyResponse from the persistent key data to use for requesting a key for
                 decrypting content.
                 */
                let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: contentKey)
                
                // Provide the content key response to make protected content available for processing.
                keyRequest.processContentKeyResponse(keyResponse)
                
                return
            }
            
            let applicationCertificate = try requestApplicationCertificate(assetId: assetIDString, contentKeyIdentifier: contentKeyIdentifierString)
            
            keyRequest.makeStreamingContentKeyRequestData(forApp: applicationCertificate,
                                                          contentIdentifier: assetIDData,
                                                          options: [AVContentKeyRequestProtocolVersionsKey: [1]],
                                                          completionHandler: completionHandler)
        } catch {
            print("Failure responding to an AVPersistableContentKeyRequest when attemping to determine if key is already available for use on disk.")
        }
    }
    
    @objc public func requestPersistableContentKeys(forUrl url: URL) {
        
        pendingPersistableContentKeyIdentifiers.insert(url.absoluteString)
            
        ContentKeyManager.shared.contentKeySession.processContentKeyRequest(withIdentifier: url.absoluteString, initializationData: nil, options: nil)
    }
    
    func writePersistableContentKey(contentKey: Data, withKid kid: String) throws {
        
        let fileURL = urlForPersistableContentKey(withKid: kid)
        
        try contentKey.write(to: fileURL, options: Data.WritingOptions.atomicWrite)
    }
    
    func urlForPersistableContentKey(withKid kid: String) -> URL {
        return contentKeyDirectory.appendingPathComponent("\(kid)-Key")
    }
    
    func persistableContentKeyExistsOnDisk(withKid kid: String) -> Bool {
        let contentKeyURL = urlForPersistableContentKey(withKid: kid)
        
        return FileManager.default.fileExists(atPath: contentKeyURL.path)
    }
    
    @objc public func deletePeristableContentKey(withKid kid: String) {
        
        guard persistableContentKeyExistsOnDisk(withKid: kid) else { return }
        
        let contentKeyURL = urlForPersistableContentKey(withKid: kid)
        
        do {
            try FileManager.default.removeItem(at: contentKeyURL)
            UserDefaults.standard.removeObject(forKey: "\(kid)-Key")
        } catch {
            print("An error occured removing the persisted content key: \(error)")
        }
    }
}

extension Notification.Name {
    
    /**
     The notification that is posted when the content key for a given asset has been saved to disk.
     */
    static let DidSavePersistableContentKey = Notification.Name("ContentKeyDelegateDidSavePersistableContentKey")
}
