//
//  ALTAppleAPI+Authentication.swift
//  AltSign
//
//  Created by Riley Testut on 8/15/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import Darwin

@_exported import CAltSign
import CAltSign.Private

public extension ALTAppleAPIError
{
    static func unknown(userInfo: [String: Any] = [:], sourceFile: String = #fileID, sourceLine: UInt = #line) -> ALTAppleAPIError
    {
        var userInfo = userInfo
        userInfo[ALTSourceFileErrorKey] = sourceFile
        userInfo[ALTSourceLineErrorKey] = sourceLine
        
        let error = ALTAppleAPIError(.unknown, userInfo: userInfo)
        return error
    }
}

public extension ALTAppleAPI
{
    @objc func authenticate(appleID unsanitizedAppleID: String,
                            password: String,
                            anisetteData: ALTAnisetteData,
                            verificationHandler: ((@escaping (String?) -> Void) -> Void)?,
                            completionHandler: @escaping (ALTAccount?, ALTAppleAPISession?, Error?) -> Void)
    {
        // Authenticating only works with lowercase email address, even if Apple ID contains capital letters.
        let sanitizedAppleID = unsanitizedAppleID.lowercased()
        
        do
        {
            let clientDictionary = [
                "bootstrap": true,
                "icscrec": true,
                "pbe": false,
                "prkgen": true,
                "svct": "iCloud",
                "loc": Locale.current.identifier,
                "X-Apple-Locale": Locale.current.identifier,
                "X-Apple-I-MD": anisetteData.oneTimePassword,
                "X-Apple-I-MD-M": anisetteData.machineID,
                "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier,
                "X-Apple-I-MD-LU": anisetteData.localUserID,
                "X-Apple-I-MD-RINFO": anisetteData.routingInfo,
                "X-Apple-I-SRL-NO": anisetteData.deviceSerialNumber,
                "X-Apple-I-Client-Time": self.dateFormatter.string(from: anisetteData.date),
                "X-Apple-I-TimeZone": TimeZone.current.abbreviation() ?? "PST",
            ] as [String: Any]
            
            let context = GSAContext(username: sanitizedAppleID, password: password)
            guard let publicKey = context.start() else { throw ALTAppleAPIError(.authenticationHandshakeFailed) }
            
            let parameters = [
                "A2k": publicKey,
                "cpd": clientDictionary,
                "ps": ["s2k", "s2k_fo"],
                "o": "init",
                "u": sanitizedAppleID
            ] as [String: Any]
            
            self.sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { (result) in
                do
                {
                    let responseDictionary = try result.get()

                    guard let c = responseDictionary["c"] as? String,
                          let salt = responseDictionary["s"] as? Data,
                          let iterations = responseDictionary["i"] as? Int,
                          let serverPublicKey = responseDictionary["B"] as? Data
                    else { throw self.authenticationResponseError(operation: "init", underlyingError: URLError(.badServerResponse)) }
                    
                    context.salt = salt
                    context.serverPublicKey = serverPublicKey
                    
                    let sp = responseDictionary["sp"] as? String
                    let isHexadecimal = (sp == "s2k_fo")                    
                    
                    guard let verificationMessage = context.makeVerificationMessage(iterations: iterations, isHexadecimal: isHexadecimal) else {
                        throw self.authenticationResponseError(operation: "complete")
                    }
                    
                    let parameters = [
                        "c": c,
                        "cpd": clientDictionary,
                        "M1": verificationMessage,
                        "o": "complete",
                        "u": sanitizedAppleID
                    ] as [String: Any]
                    
                    self.sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { (result) in
                        do
                        {
                            let responseDictionary = try result.get()
                            
                            guard let serverVerificationMessage = responseDictionary["M2"] as? Data,
                                  let serverDictionary = responseDictionary["spd"] as? Data,
                                  let statusDictionary = responseDictionary["Status"] as? [String: Any]
                            else { throw self.authenticationResponseError(operation: "complete", underlyingError: URLError(.badServerResponse)) }
                            
                            guard context.verifyServerVerificationMessage(serverVerificationMessage) else { throw self.authenticationResponseError(operation: "complete") }
                            guard let decryptedData = serverDictionary.decryptedCBC(context: context) else { throw self.authenticationResponseError(operation: "complete.decrypted") }
                            
                            let decryptedDictionary = try self.authenticationDictionary(from: decryptedData, operation: "complete.decrypted")
                            guard let dsid = decryptedDictionary["adsid"] as? String,
                                  let idmsToken = decryptedDictionary["GsIdmsToken"] as? String
                            else { throw self.authenticationResponseError(operation: "complete.decrypted", underlyingError: URLError(.badServerResponse)) }
                            
                            context.dsid = dsid
                            
                            let authType = statusDictionary["au"] as? String
                            switch authType
                            {
                            case "trustedDeviceSecondaryAuth":
                                guard let verificationHandler = verificationHandler else { throw ALTAppleAPIError(.requiresTwoFactorAuthentication) }
                                
                                self.requestTrustedDeviceTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler) { (result) in
                                    switch result
                                    {
                                    case .failure(let error): completionHandler(nil, nil, error)
                                    case .success:
                                        self.authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: anisetteData, verificationHandler: verificationHandler, completionHandler: completionHandler)
                                    }
                                }
                                
                            case "secondaryAuth":
                                guard let verificationHandler = verificationHandler else { throw ALTAppleAPIError(.requiresTwoFactorAuthentication) }
                                
                                self.requestSMSTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler) { (result) in
                                    switch result
                                    {
                                    case .failure(let error): completionHandler(nil, nil, error)
                                    case .success:
                                        self.authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: anisetteData, verificationHandler: verificationHandler, completionHandler: completionHandler)
                                    }
                                }
                                
                            default:
                                guard let sessionKey = decryptedDictionary["sk"] as? Data,
                                      let c = decryptedDictionary["c"] as? Data
                                else { throw self.authenticationResponseError(operation: "complete.decrypted", underlyingError: URLError(.badServerResponse)) }
                                
                                context.sessionKey = sessionKey
                                
                                let app = "com.apple.gs.xcode.auth"
                                guard let checksum = context.makeChecksum(appName: app) else { throw self.authenticationResponseError(operation: "apptokens") }
                                
                                let parameters = [
                                    "app": [app],
                                    "c": c,
                                    "checksum": checksum,
                                    "cpd": clientDictionary,
                                    "o": "apptokens",
                                    "t": idmsToken,
                                    "u": dsid
                                ] as [String: Any]
                                
                                self.fetchAuthToken(app: app, parameters: parameters, context: context, anisetteData: anisetteData) { (result) in
                                    switch result
                                    {
                                    case .failure(let error): completionHandler(nil, nil, error)
                                    case .success(let token):
                                        
                                        let session = ALTAppleAPISession(dsid: dsid, authToken: token, anisetteData: anisetteData)
                                        self.fetchAccount(session: session) { (result) in
                                            switch result
                                            {
                                            case .failure(let error): completionHandler(nil, nil, error)
                                            case .success(let account): completionHandler(account, session, nil)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        catch
                        {
                            completionHandler(nil, nil, error)
                        }
                    }
                }
                catch
                {
                    completionHandler(nil, nil, error)
                }
            }
        }
        catch
        {
            completionHandler(nil, nil, error)
        }
    }
}

private extension ALTAppleAPI
{
    func fetchAuthToken(app: String, parameters: [String: Any], context: GSAContext, anisetteData: ALTAnisetteData, completionHandler: @escaping (Result<String, Error>) -> Void)
    {
        self.sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { (result) in
            do
            {
                let responseDictionary = try result.get()
                
                guard let encryptedToken = responseDictionary["et"] as? Data else { throw self.authenticationResponseError(operation: "apptokens", underlyingError: URLError(.badServerResponse)) }
                guard let token = encryptedToken.decryptedGCM(context: context) else { throw self.authenticationResponseError(operation: "apptokens.decrypted") }
                
                let tokensDictionary = try self.authenticationDictionary(from: token, operation: "apptokens.decrypted")
                
                guard let appTokens = tokensDictionary["t"] as? [String: Any],
                      let tokens = appTokens[app] as? [String: Any],
                      let authToken = tokens["token"] as? String
                else { throw self.authenticationResponseError(operation: "apptokens.decrypted", underlyingError: URLError(.badServerResponse)) }
                
                completionHandler(.success(authToken))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func requestTrustedDeviceTwoFactorCode(dsid: String,
                                           idmsToken: String,
                                           anisetteData: ALTAnisetteData,
                                           verificationHandler: @escaping (@escaping (String?) -> Void) -> Void,
                                           completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!
        let verifyURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!
        
        let request = self.makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        
        let requestCodeTask = self.session.dataTask(with: request) { (data, response, error) in
            do
            {
                guard error == nil else { throw error! }
                try self.validateAuthenticationHTTP(response, operation: "trusted-device.request")
                
                func responseHandler(verificationCode: String?)
                {
                    do
                    {
                        guard let verificationCode = verificationCode else { throw ALTAppleAPIError(.requiresTwoFactorAuthentication) }
                                                
                        var request = self.makeTwoFactorCodeRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
                        request.allHTTPHeaderFields?["security-code"] = verificationCode
                        
                        let verifyCodeTask = self.session.dataTask(with: request) { (data, response, error) in
                            do
                            {
                                if let error = error { throw error }
                                guard let data = data else {
                                    throw self.authenticationResponseError(operation: "trusted-device.verify", response: response)
                                }
                                try self.validateTrustedDeviceResponse(from: data, response: response)
                                completionHandler(.success(()))
                            }
                            catch
                            {
                                completionHandler(.failure(error))
                            }
                        }
                        
                        verifyCodeTask.resume()
                    }
                    catch
                    {
                        completionHandler(.failure(error))
                    }
                }
                
                verificationHandler(responseHandler)
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        
        requestCodeTask.resume()
    }
    
    func requestSMSTwoFactorCode(dsid: String,
                                 idmsToken: String,
                                 anisetteData: ALTAnisetteData,
                                 verificationHandler: @escaping (@escaping (String?) -> Void) -> Void,
                                 completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/phone/put?mode=sms")!
        let verifyURL = URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode?referrer=/auth/verify/phone/put")!

        var request = self.makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        request.httpMethod = "POST"

        do
        {
            let bodyXML = [
                "serverInfo": [
                    "phoneNumber.id": "1"
                ]
            ] as [String : Any]
            
            let bodyData = try PropertyListSerialization.data(fromPropertyList: bodyXML, format: .xml, options: 0)
            request.httpBody = bodyData
        }
        catch
        {
            completionHandler(.failure(error))
            return
        }
        
        let requestCodeTask = self.session.dataTask(with: request) { (data, response, error) in
            do
            {
                guard error == nil else { throw error! }
                try self.validateAuthenticationHTTP(response, operation: "sms.request")
                
                func responseHandler(verificationCode: String?)
                {
                    do
                    {
                        guard let verificationCode = verificationCode else { throw ALTAppleAPIError(.requiresTwoFactorAuthentication) }
                        
                        var request = self.makeTwoFactorCodeRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
                        request.httpMethod = "POST"
                        
                        let bodyXML = [
                            "securityCode.code": verificationCode,
                            "serverInfo": [
                                "mode": "sms",
                                "phoneNumber.id": "1"
                            ]
                        ] as [String : Any]
                        
                        let bodyData = try PropertyListSerialization.data(fromPropertyList: bodyXML, format: .xml, options: 0)
                        request.httpBody = bodyData
                        
                        let verifyCodeTask = self.session.dataTask(with: request) { (data, response, error) in
                            do
                            {
                                guard error == nil else { throw error! }
                                                                
                                try self.validateSMSVerificationResponse(response)

                                completionHandler(.success(()))
                            }
                            catch
                            {
                                completionHandler(.failure(error))
                            }
                        }
                        
                        verifyCodeTask.resume()
                    }
                    catch
                    {
                        completionHandler(.failure(error))
                    }
                }
                
                verificationHandler(responseHandler)
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        
        requestCodeTask.resume()
    }
    
    func fetchAccount(session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTAccount, Error>) -> Void)
    {
        let url = URL(string: "viewDeveloper.action", relativeTo: self.baseURL)!
        
        self.sendRequest(with: url, additionalParameters: nil, session: session, team: nil) { (responseDictionary, requestError) in
            do
            {
                guard let responseDictionary = responseDictionary else { throw requestError ?? ALTAppleAPIError.unknown() }
                
                guard let account = try self.processResponse(responseDictionary, parseHandler: { () -> Any? in
                    guard let dictionary = responseDictionary["developer"] as? [String: Any] else { return nil }
                    let account = ALTAccount(responseDictionary: dictionary)
                    return account
                }, resultCodeHandler: nil) as? ALTAccount else {
                    throw ALTAppleAPIError.unknown()
                }
                
                completionHandler(.success(account))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
}

private extension ALTAppleAPI
{
    var authenticationUserAgent: String
    {
        var components = ["akd/1.0"]

        let cfNetworkBundle = Bundle(identifier: "com.apple.CFNetwork") ?? Bundle(path: "/System/Library/Frameworks/CFNetwork.framework")
        if let version = cfNetworkBundle?.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String, !version.isEmpty
        {
            components.append("CFNetwork/\(version)")
        }

        var systemInfo = utsname()
        if uname(&systemInfo) == 0
        {
            let release = withUnsafePointer(to: &systemInfo.release) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            components.append("Darwin/\(release)")
        }

        return components.joined(separator: " ")
    }

    func sendAuthenticationRequest(parameters requestParameters: [String: Any], anisetteData: ALTAnisetteData, completionHandler: @escaping (Result<[String: Any], Error>) -> Void)
    {
        let operation = Self.authenticationOperation(from: requestParameters)

        do
        {
            let requestURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
            
            let parameters = [
                "Header": ["Version": "1.0.1"],
                "Request": requestParameters
            ]
            
            let httpHeaders = [
                "Content-Type": "text/x-xml-plist",
                "X-MMe-Client-Info": anisetteData.deviceDescription,
                "Accept": "*/*",
                "User-Agent": self.authenticationUserAgent
            ]
            
            let bodyData = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)
            
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
            
            let dataTask = self.session.dataTask(with: request) { (data, response, error) in
                do
                {
                    if let error = error { throw error }
                    guard let data = data else
                    {
                        throw self.authenticationResponseError(operation: operation, response: response, underlyingError: URLError(.badServerResponse))
                    }

                    let dictionary = try self.authenticationServiceDictionary(from: data, operation: operation, response: response)
                    completionHandler(.success(dictionary))
                }
                catch
                {
                    completionHandler(.failure(error))
                }
            }
            
            dataTask.resume()
        }
        catch
        {
            completionHandler(.failure(self.authenticationResponseError(operation: "request.encoding", underlyingError: error)))
        }
    }

}

// Internal visibility lets regression tests exercise the production parser without a live account.
extension ALTAppleAPI
{

    func validateAuthenticationHTTP(_ response: URLResponse?, operation: String) throws
    {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw self.authenticationResponseError(operation: operation, response: response, underlyingError: URLError(.badServerResponse))
        }
    }

    func authenticationServiceDictionary(from data: Data, operation: String, response: URLResponse?) throws -> [String: Any]
    {
        let envelope = try self.authenticationDictionary(from: data, operation: operation, response: response)
        guard let dictionary = envelope["Response"] as? [String: Any],
              let status = dictionary["Status"] as? [String: Any],
              let errorCode = status["ec"] as? Int
        else { throw self.authenticationResponseError(operation: operation, response: response, underlyingError: URLError(.badServerResponse)) }

        // Structured Apple errors take precedence over the HTTP status.
        if errorCode != 0
        {
            switch errorCode
            {
            case -20101, -22406: throw ALTAppleAPIError(.incorrectCredentials)
            case -22421: throw ALTAppleAPIError(.invalidAnisetteData)
            default: throw NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: errorCode, userInfo: nil)
            }
        }
        try self.validateAuthenticationHTTP(response, operation: operation)
        return dictionary
    }

    func validateTrustedDeviceResponse(from data: Data, response: URLResponse?) throws
    {
        let dictionary = try self.authenticationDictionary(from: data, operation: "trusted-device.verify", response: response)
        guard let code = dictionary["ec"] as? Int else {
            throw self.authenticationResponseError(operation: "trusted-device.verify", response: response, underlyingError: URLError(.badServerResponse))
        }
        if code == -21669 { throw ALTAppleAPIError(.incorrectVerificationCode) }
        if code != 0 { throw NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: code, userInfo: nil) }
        try self.validateAuthenticationHTTP(response, operation: "trusted-device.verify")
    }

    func validateSMSVerificationResponse(_ response: URLResponse?) throws
    {
        try self.validateAuthenticationHTTP(response, operation: "sms.verify")
        guard let http = response as? HTTPURLResponse,
              let token = http.value(forHTTPHeaderField: "X-Apple-PE-Token"), !token.isEmpty else {
            throw ALTAppleAPIError(.incorrectVerificationCode)
        }
    }

    static func authenticationOperation(from requestParameters: [String: Any]) -> String
    {
        guard let operation = requestParameters["o"] as? String,
              ["init", "complete", "apptokens"].contains(operation)
        else { return "unknown" }

        return operation
    }

    func authenticationDictionary(from data: Data, operation: String, response: URLResponse? = nil) throws -> [String: Any]
    {
        do
        {
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { throw URLError(.badServerResponse) }

            return dictionary
        }
        catch
        {
            // Apple and network intermediaries can return HTML or malformed data. Keep only
            // bounded transport metadata so diagnostics never retain or log the response body.
            throw self.authenticationResponseError(operation: operation, response: response, underlyingError: error)
        }
    }

    func authenticationResponseError(operation: String, response: URLResponse? = nil, underlyingError: Error? = nil) -> ALTAppleAPIError
    {
        var userInfo = [String: Any]()
        let operations = ["init", "complete", "apptokens", "complete.decrypted", "apptokens.decrypted",
                          "trusted-device.request", "trusted-device.verify", "sms.request", "sms.verify", "request.encoding"]
        userInfo[ALTAppleAPIRequestOperationErrorKey] = operations.contains(operation) ? operation : "unknown"

        if let httpResponse = response as? HTTPURLResponse
        {
            userInfo[ALTAppleAPIHTTPStatusCodeErrorKey] = NSNumber(value: httpResponse.statusCode)
        }

        if let mimeType = response?.mimeType?.lowercased(), !mimeType.isEmpty
        {
            let types = ["text/html", "application/xhtml+xml", "text/x-xml-plist", "application/x-plist",
                         "application/x-apple-plist", "application/xml", "text/xml", "application/json"]
            userInfo[ALTAppleAPIResponseMIMETypeErrorKey] = types.contains(mimeType) ? mimeType : "other"
        }

        if let underlyingError = underlyingError
        {
            // Foundation parser descriptions can include fragments of the response.
            let error = underlyingError as NSError
            userInfo[NSUnderlyingErrorKey] = NSError(domain: error.domain, code: error.code, userInfo: nil)
        }

        return ALTAppleAPIError(.authenticationHandshakeFailed, userInfo: userInfo)
    }
    
}

private extension ALTAppleAPI
{
    func makeTwoFactorCodeRequest(url: URL,
                                  dsid: String,
                                  idmsToken: String,
                                  anisetteData: ALTAnisetteData) -> URLRequest
    {
        let identityToken = dsid + ":" + idmsToken
        
        let identityTokenData = identityToken.data(using: .utf8)!
        let encodedIdentityToken = identityTokenData.base64EncodedString()
        
        let httpHeaders = [
            "Accept": "application/x-buddyml",
            "Accept-Language": "en-us",
            "Content-Type": "application/x-plist",
            "User-Agent": "Xcode",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": ALTAppleXcodeVersion,
            "X-Apple-Identity-Token": encodedIdentityToken,
            "X-Apple-I-MD-M": anisetteData.machineID,
            "X-Apple-I-MD": anisetteData.oneTimePassword,
            "X-Apple-I-MD-LU": anisetteData.localUserID,
            "X-Apple-I-MD-RINFO": "\(anisetteData.routingInfo)",
            "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier,
            "X-MMe-Client-Info": anisetteData.deviceDescription,
            "X-Apple-I-Client-Time": self.dateFormatter.string(from: anisetteData.date),
            "X-Apple-Locale": anisetteData.locale.identifier,
            "X-Apple-I-TimeZone": anisetteData.timeZone.abbreviation() ?? "PST"
        ]
        
        var request = URLRequest(url: url)
        httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        
        return request
    }
}
