import Darwin
import Foundation

public final class SingleInstanceLock {
    private let lockFileURL: URL
    private var fileDescriptor: Int32 = -1

    public init(lockFileURL: URL) {
        self.lockFileURL = lockFileURL
    }

    deinit {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    public func acquire() -> Bool {
        if fileDescriptor >= 0 {
            return true
        }

        let descriptor = Darwin.open(
            lockFileURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        fileDescriptor = descriptor
        return true
    }
}
