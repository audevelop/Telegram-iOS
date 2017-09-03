import Foundation
#if os(macOS)
    import SwiftSignalKitMac
#else
    import SwiftSignalKit
#endif

public enum MediaResourceStatus: Equatable {
    case Remote
    case Local
    case Fetching(progress: Float)
}

public func ==(lhs: MediaResourceStatus, rhs: MediaResourceStatus) -> Bool {
    switch lhs {
        case .Remote:
            switch rhs {
                case .Remote:
                    return true
                default:
                    return false
            }
        case .Local:
            switch rhs {
                case .Local:
                    return true
                default:
                    return false
            }
        case let .Fetching(lhsProgress):
            switch rhs {
                case let .Fetching(rhsProgress):
                    return lhsProgress.isEqual(to: rhsProgress)
                default:
                    return false
            }
    }
}
