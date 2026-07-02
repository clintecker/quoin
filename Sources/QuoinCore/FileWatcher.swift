import Foundation

/// Watches a single file for external changes, including the atomic-save
/// pattern most editors use (write temp file, rename over the original,
/// which replaces the inode). On delete/rename the watcher re-opens the
/// path and keeps going.
///
/// Events are debounced (~50 ms) and coalesced before `onChange` fires.
public final class FileWatcher: @unchecked Sendable {

    private let url: URL
    private let queue = DispatchQueue(label: "quoin.filewatcher")
    private let onChange: @Sendable () -> Void
    private var isCancelled = false

    #if canImport(Darwin)
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pendingFire: DispatchWorkItem?
    #endif

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit { cancel() }

    public func start() {
        #if canImport(Darwin)
        queue.async { [weak self] in self?.openAndWatch() }
        #endif
    }

    public func cancel() {
        #if canImport(Darwin)
        queue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.tearDown()
        }
        #endif
    }

    #if canImport(Darwin)
    private func openAndWatch() {
        guard !isCancelled else { return }
        tearDown()

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // The file may be mid-replace; retry shortly.
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.openAndWatch() }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // Atomic save: the inode is gone. Re-open the path, then
                // report the change once the new file is watchable.
                self.openAndWatch()
                self.scheduleFire()
            } else {
                self.scheduleFire()
            }
        }
        source.setCancelHandler { [fileDescriptor] in
            if fileDescriptor >= 0 { close(fileDescriptor) }
        }
        self.source = source
        source.resume()
    }

    private func scheduleFire() {
        pendingFire?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onChange()
        }
        pendingFire = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func tearDown() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
    #endif
}
