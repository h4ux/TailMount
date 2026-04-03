import Foundation

enum MountState: Equatable {
    case unmounted
    case mounting
    case mounted
    case unmounting
    case error(String)

    var label: String {
        switch self {
        case .unmounted:       return "Not Mounted"
        case .mounting:        return "Mounting..."
        case .mounted:         return "Mounted"
        case .unmounting:      return "Unmounting..."
        case .error(let msg):  return "Error: \(msg)"
        }
    }

    var isBusy: Bool {
        self == .mounting || self == .unmounting
    }
}
