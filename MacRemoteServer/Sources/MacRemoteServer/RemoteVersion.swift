import Foundation

enum RemoteProtocol {
    static let version = 1
    static let acceptedMinimum = 1
    static let acceptedMaximum = 1

    static var acceptedRangeDescription: String {
        acceptedMinimum == acceptedMaximum
            ? "\(acceptedMinimum)"
            : "\(acceptedMinimum)–\(acceptedMaximum)"
    }

    static func accepts(_ version: Int) -> Bool {
        (acceptedMinimum...acceptedMaximum).contains(version)
    }
}

enum RemoteAppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var display: String { "\(short) (\(build))" }

    static func isNewer(_ candidate: String, than current: String = short) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
