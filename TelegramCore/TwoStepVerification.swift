import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
#else
    import Postbox
    import SwiftSignalKit
    import MtProtoKitDynamic
#endif

public enum TwoStepVerificationConfiguration {
    case notSet(pendingEmailPattern: String)
    case set(hint: String, hasRecoveryEmail: Bool, pendingEmailPattern: String)
}

public func twoStepVerificationConfiguration(account: Account) -> Signal<TwoStepVerificationConfiguration, NoError> {
    return account.network.request(Api.functions.account.getPassword())
        |> retryRequest
        |> map { result -> TwoStepVerificationConfiguration in
            switch result {
                case let .password(password):
                    if password.currentAlgo != nil {
                        return .set(hint: password.hint ?? "", hasRecoveryEmail: (password.flags & (1 << 0)) != 0, pendingEmailPattern: password.emailUnconfirmedPattern ?? "")
                    } else {
                        return .notSet(pendingEmailPattern: password.emailUnconfirmedPattern ?? "")
                    }
            }
        }
}

public struct TwoStepVerificationSecureSecret {
    public let data: Data
    public let derivation: TwoStepSecurePasswordDerivation
    public let id: Int64
}

public struct TwoStepVerificationSettings {
    public let email: String
    public let secureSecret: TwoStepVerificationSecureSecret?
}

public func requestTwoStepVerifiationSettings(network: Network, password: String) -> Signal<TwoStepVerificationSettings, AuthorizationPasswordVerificationError> {
    return twoStepAuthData(network)
    |> mapError { error -> AuthorizationPasswordVerificationError in
        if error.errorDescription.hasPrefix("FLOOD_WAIT") {
            return .limitExceeded
        } else if error.errorDescription == "PASSWORD_HASH_INVALID" {
            return .invalidPassword
        } else {
            return .generic
        }
    }
    |> mapToSignal { authData -> Signal<TwoStepVerificationSettings, AuthorizationPasswordVerificationError> in
        guard let currentPasswordDerivation = authData.currentPasswordDerivation else {
            return .fail(.generic)
        }
        
        guard let currentPasswordHash = passwordKDF(password: password, derivation: currentPasswordDerivation) else {
            return .fail(.generic)
        }
        
        return network.request(Api.functions.account.getPasswordSettings(currentPasswordHash: Buffer(data: currentPasswordHash)), automaticFloodWait: false)
        |> mapError { _ -> AuthorizationPasswordVerificationError in
            return .generic
        }
        |> mapToSignal { result -> Signal<TwoStepVerificationSettings, AuthorizationPasswordVerificationError> in
            switch result {
                case let .passwordSettings(_, email, secureSettings):
                    var parsedSecureSecret: TwoStepVerificationSecureSecret?
                    if let secureSettings = secureSettings {
                        switch secureSettings {
                            case let .secureSecretSettings(secureAlgo, secureSecret, secureSecretId):
                                if secureSecret.size != 32 {
                                    return .fail(.generic)
                                }
                                parsedSecureSecret = TwoStepVerificationSecureSecret(data: secureSecret.makeData(), derivation: TwoStepSecurePasswordDerivation(secureAlgo), id: secureSecretId)
                        }
                    }
                    return .single(TwoStepVerificationSettings(email: email ?? "", secureSecret: parsedSecureSecret))
            }
        }
    }
}

public enum UpdateTwoStepVerificationPasswordError {
    case generic
    case invalidEmail
}

public enum UpdateTwoStepVerificationPasswordResult {
    case none
    case password(password: String, pendingEmailPattern: String?)
}

public enum UpdatedTwoStepVerificationPassword {
    case none
    case password(password: String, hint: String, email: String?)
}

public func updateTwoStepVerificationPassword(network: Network, currentPassword: String?, updatedPassword: UpdatedTwoStepVerificationPassword) -> Signal<UpdateTwoStepVerificationPasswordResult, UpdateTwoStepVerificationPasswordError> {
    return twoStepAuthData(network)
    |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
        return .generic
    }
    |> mapToSignal { authData -> Signal<(TwoStepAuthData, TwoStepVerificationSecureSecret?), UpdateTwoStepVerificationPasswordError> in
        if let _ = authData.currentPasswordDerivation {
            return requestTwoStepVerifiationSettings(network: network, password: currentPassword ?? "")
            |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
                return .generic
            }
            |> map { settings in
                return (authData, settings.secureSecret)
            }
        } else {
            return .single((authData, nil))
        }
    }
    |> mapToSignal { authData, secureSecret -> Signal<UpdateTwoStepVerificationPasswordResult, UpdateTwoStepVerificationPasswordError> in
        let currentPasswordHash: Buffer
        if let currentPasswordDerivation = authData.currentPasswordDerivation {
            if let passwordHash = passwordKDF(password: currentPassword ?? "", derivation: currentPasswordDerivation) {
                currentPasswordHash = Buffer(data: passwordHash)
            } else {
                return .fail(.generic)
            }
        } else {
            currentPasswordHash = Buffer(data: Data())
        }
        
        switch updatedPassword {
            case .none:
                var flags: Int32 = (1 << 1)
                if authData.currentPasswordDerivation != nil {
                    flags |= (1 << 0)
                }
                
                return network.request(Api.functions.account.updatePasswordSettings(currentPasswordHash: currentPasswordHash, newSettings: .passwordInputSettings(flags: flags, newAlgo: .passwordKdfAlgoUnknown, newPasswordHash: Buffer(data: Data()), hint: "", email: "", newSecureSettings: nil)), automaticFloodWait: true)
                |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
                    return .generic
                }
                |> map { _ -> UpdateTwoStepVerificationPasswordResult in
                    return .none
                }
            case let .password(password, hint, email):
                var flags: Int32 = 1 << 0
                if email != nil {
                    flags |= (1 << 1)
                }
                
                guard let (updatedPasswordHash, updatedPasswordDerivation) = passwordUpdateKDF(password: password, derivation: authData.nextPasswordDerivation) else {
                    return .fail(.generic)
                }
                
                var updatedSecureSecret: TwoStepVerificationSecureSecret?
                if let encryptedSecret = secureSecret {
                    if let decryptedSecret = decryptedSecureSecret(encryptedSecretData: encryptedSecret.data, password: currentPassword ?? "", derivation: encryptedSecret.derivation, id: encryptedSecret.id) {
                        if let (data, derivation, id) = encryptedSecureSecret(secretData: decryptedSecret, password: password, inputDerivation: authData.nextSecurePasswordDerivation) {
                            updatedSecureSecret = TwoStepVerificationSecureSecret(data: data, derivation: derivation, id: id)
                        } else {
                            return .fail(.generic)
                        }
                    } else {
                        return .fail(.generic)
                    }
                }
                
                var updatedSecureSettings: Api.SecureSecretSettings?
                if let updatedSecureSecret = updatedSecureSecret {
                    flags |= 1 << 2
                    updatedSecureSettings = .secureSecretSettings(secureAlgo: updatedSecureSecret.derivation.apiAlgo, secureSecret: Buffer(data: updatedSecureSecret.data), secureSecretId: updatedSecureSecret.id)
                }
                
                return network.request(Api.functions.account.updatePasswordSettings(currentPasswordHash: currentPasswordHash, newSettings: Api.account.PasswordInputSettings.passwordInputSettings(flags: flags, newAlgo: updatedPasswordDerivation.apiAlgo, newPasswordHash: Buffer(data: updatedPasswordHash), hint: hint, email: email, newSecureSettings: updatedSecureSettings)), automaticFloodWait: false)
                |> map { _ -> UpdateTwoStepVerificationPasswordResult in
                    return .password(password: password, pendingEmailPattern: nil)
                }
                |> `catch` { error -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
                    if error.errorDescription == "EMAIL_UNCONFIRMED" {
                        return twoStepAuthData(network)
                            |> map { result -> UpdateTwoStepVerificationPasswordResult in
                                return .password(password: password, pendingEmailPattern: result.unconfirmedEmailPattern)
                            }
                    } else {
                        return .fail(error)
                    }
                }
                |> mapError { error -> UpdateTwoStepVerificationPasswordError in
                    if error.errorDescription == "EMAIL_INVALID" {
                        return .invalidEmail
                    } else {
                        return .generic
                    }
                }
        }
    }
}

enum UpdateTwoStepVerificationSecureSecretResult {
    case success
}

enum UpdateTwoStepVerificationSecureSecretError {
    case generic
}

func updateTwoStepVerificationSecureSecret(network: Network, password: String, secret: Data) -> Signal<UpdateTwoStepVerificationSecureSecretResult, UpdateTwoStepVerificationSecureSecretError> {
    return twoStepAuthData(network)
    |> mapError { _ -> UpdateTwoStepVerificationSecureSecretError in
        return .generic
    }
    |> mapToSignal { authData -> Signal<UpdateTwoStepVerificationSecureSecretResult, UpdateTwoStepVerificationSecureSecretError> in
        guard let currentPasswordDerivation = authData.currentPasswordDerivation else {
            return .fail(.generic)
        }
        
        guard let currentPasswordHash = passwordKDF(password: password, derivation: currentPasswordDerivation) else {
            return .fail(.generic)
        }
        
        guard let (encryptedSecret, secretDerivation, secretId) = encryptedSecureSecret(secretData: secret, password: password, inputDerivation: authData.nextSecurePasswordDerivation) else {
            return .fail(.generic)
        }
        
        let flags: Int32 = (1 << 2)
        return network.request(Api.functions.account.updatePasswordSettings(currentPasswordHash: Buffer(data: currentPasswordHash), newSettings: .passwordInputSettings(flags: flags, newAlgo: nil, newPasswordHash: nil, hint: "", email: "", newSecureSettings: .secureSecretSettings(secureAlgo: secretDerivation.apiAlgo, secureSecret: Buffer(data: encryptedSecret), secureSecretId: secretId))), automaticFloodWait: true)
        |> mapError { _ -> UpdateTwoStepVerificationSecureSecretError in
            return .generic
        }
        |> map { _ -> UpdateTwoStepVerificationSecureSecretResult in
            return .success
        }
    }
}

public func updateTwoStepVerificationEmail(account: Account, currentPassword: String, updatedEmail: String) -> Signal<UpdateTwoStepVerificationPasswordResult, UpdateTwoStepVerificationPasswordError> {
    return twoStepAuthData(account.network)
    |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
        return .generic
    }
    |> mapToSignal { authData -> Signal<UpdateTwoStepVerificationPasswordResult, UpdateTwoStepVerificationPasswordError> in
        let currentPasswordHash: Buffer
        if let currentPasswordDerivation = authData.currentPasswordDerivation {
            guard let passwordHash = passwordKDF(password: currentPassword, derivation: currentPasswordDerivation) else {
                return .fail(.generic)
            }
            currentPasswordHash = Buffer(data: passwordHash)
        } else {
            currentPasswordHash = Buffer(data: Data())
        }

        let flags: Int32 = 1 << 1
        return account.network.request(Api.functions.account.updatePasswordSettings(currentPasswordHash: currentPasswordHash, newSettings: Api.account.PasswordInputSettings.passwordInputSettings(flags: flags, newAlgo: nil, newPasswordHash: nil, hint: nil, email: updatedEmail, newSecureSettings: nil)), automaticFloodWait: false)
        |> map { _ -> UpdateTwoStepVerificationPasswordResult in
            return .password(password: currentPassword, pendingEmailPattern: nil)
        }
        |> `catch` { error -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
            if error.errorDescription == "EMAIL_UNCONFIRMED" {
                return twoStepAuthData(account.network)
                    |> map { result -> UpdateTwoStepVerificationPasswordResult in
                        return .password(password: currentPassword, pendingEmailPattern: result.unconfirmedEmailPattern)
                }
            } else {
                return .fail(error)
            }
        }
        |> mapError { error -> UpdateTwoStepVerificationPasswordError in
            if error.errorDescription == "EMAIL_INVALID" {
                return .invalidEmail
            } else {
                return .generic
            }
        }
    }
}

public enum RequestTwoStepVerificationPasswordRecoveryCodeError {
    case generic
}

public func requestTwoStepVerificationPasswordRecoveryCode(network: Network) -> Signal<String, RequestTwoStepVerificationPasswordRecoveryCodeError> {
    return network.request(Api.functions.auth.requestPasswordRecovery(), automaticFloodWait: false)
        |> mapError { _ -> RequestTwoStepVerificationPasswordRecoveryCodeError in
            return .generic
        }
        |> map { result -> String in
            switch result {
                case let .passwordRecovery(emailPattern):
                    return emailPattern
            }
        }
}

public enum RecoverTwoStepVerificationPasswordError {
    case generic
    case codeExpired
    case limitExceeded
    case invalidCode
}

public func recoverTwoStepVerificationPassword(network: Network, code: String) -> Signal<Void, RecoverTwoStepVerificationPasswordError> {
    return network.request(Api.functions.auth.recoverPassword(code: code), automaticFloodWait: false)
        |> mapError { error -> RecoverTwoStepVerificationPasswordError in
            if error.errorDescription.hasPrefix("FLOOD_WAIT_") {
                return .limitExceeded
            } else if error.errorDescription == "PASSWORD_RECOVERY_EXPIRED" {
                return .codeExpired
            } else if error.errorDescription == "CODE_INVALID" {
                return .invalidCode
            } else {
                return .generic
            }
        }
        |> mapToSignal { _ -> Signal<Void, RecoverTwoStepVerificationPasswordError> in
            return .complete()
        }
}

public struct TemporaryTwoStepPasswordToken: PostboxCoding, Equatable {
    public let token: Data
    public let validUntilDate: Int32
    public let requiresBiometrics: Bool
    
    public init(token: Data, validUntilDate: Int32, requiresBiometrics: Bool) {
        self.token = token
        self.validUntilDate = validUntilDate
        self.requiresBiometrics = requiresBiometrics
    }
    
    public init(decoder: PostboxDecoder) {
        self.token = decoder.decodeBytesForKey("t")!.makeData()
        self.validUntilDate = decoder.decodeInt32ForKey("d", orElse: 0)
        self.requiresBiometrics = decoder.decodeInt32ForKey("b", orElse: 0) != 0
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeBytes(MemoryBuffer(data: self.token), forKey: "t")
        encoder.encodeInt32(self.validUntilDate, forKey: "d")
        encoder.encodeInt32(self.requiresBiometrics ? 1 : 0, forKey: "b")
    }
    
    public static func ==(lhs: TemporaryTwoStepPasswordToken, rhs: TemporaryTwoStepPasswordToken) -> Bool {
        return lhs.token == rhs.token && lhs.validUntilDate == rhs.validUntilDate && lhs.requiresBiometrics == rhs.requiresBiometrics
    }
}

public func cachedTwoStepPasswordToken(postbox: Postbox) -> Signal<TemporaryTwoStepPasswordToken?, NoError> {
    return postbox.transaction { transaction -> TemporaryTwoStepPasswordToken? in
        let key = ValueBoxKey(length: 1)
        key.setUInt8(0, value: 0)
        return transaction.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedTwoStepToken, key: key)) as? TemporaryTwoStepPasswordToken
    }
}

public func cacheTwoStepPasswordToken(postbox: Postbox, token: TemporaryTwoStepPasswordToken?) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let key = ValueBoxKey(length: 1)
        key.setUInt8(0, value: 0)
        if let token = token {
            transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedTwoStepToken, key: key), entry: token, collectionSpec: ItemCacheCollectionSpec(lowWaterItemCount: 1, highWaterItemCount: 1))
        } else {
            transaction.removeItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedTwoStepToken, key: key))
        }
    }
}

public func requestTemporaryTwoStepPasswordToken(account: Account, password: String, period: Int32, requiresBiometrics: Bool) -> Signal<TemporaryTwoStepPasswordToken, AuthorizationPasswordVerificationError> {
    return twoStepAuthData(account.network)
    |> mapToSignal { authData -> Signal<TemporaryTwoStepPasswordToken, MTRpcError> in
        guard let currentPasswordDerivation = authData.currentPasswordDerivation else {
            return .fail(MTRpcError(errorCode: 400, errorDescription: "NO_PASSWORD"))
        }
        guard let currentPasswordHash = passwordKDF(password: password, derivation: currentPasswordDerivation) else {
            return .fail(MTRpcError(errorCode: 400, errorDescription: "KDF_ERROR"))
        }
        
        return account.network.request(Api.functions.account.getTmpPassword(passwordHash: Buffer(data: currentPasswordHash), period: period), automaticFloodWait: false)
        |> map { result -> TemporaryTwoStepPasswordToken in
            switch result {
                case let .tmpPassword(tmpPassword, validUntil):
                    return TemporaryTwoStepPasswordToken(token: tmpPassword.makeData(), validUntilDate: validUntil, requiresBiometrics: requiresBiometrics)
            }
        }
    }
    |> `catch` { error -> Signal<TemporaryTwoStepPasswordToken, AuthorizationPasswordVerificationError> in
        if error.errorDescription.hasPrefix("FLOOD_WAIT") {
            return .fail(.limitExceeded)
        } else if error.errorDescription == "PASSWORD_HASH_INVALID" {
            return .fail(.invalidPassword)
        } else {
            return .fail(.generic)
        }
    }
}
