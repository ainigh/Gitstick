import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// Notifies when something in a folder changed. Ignores the .git directory, because our own
/// commits write there and would otherwise trigger an endless sync loop.
public protocol FolderWatcher: AnyObject {
    func start(onChange: @escaping () -> Void)
    func stop()
}

public func makeWatcher(for root: URL) -> FolderWatcher {
    #if os(macOS)
    return FSEventsWatcher(root: root)
    #else
    return PollingWatcher(root: root)
    #endif
}

/// Turns a burst of file events into one sync.
///
/// Waits until the folder has been quiet for `quiet` seconds (an app's save, a big drag-and-drop,
/// an unzip all settle first), but never longer than `maxWait` after the first event, so a
/// constantly-changing folder still syncs periodically.
public final class Debouncer: @unchecked Sendable {
    public let quiet: TimeInterval
    public let maxWait: TimeInterval
    private let action: () -> Void
    private let queue = DispatchQueue(label: "gitstick.debounce")
    private var firstEvent: Date?
    private var work: DispatchWorkItem?

    public init(quiet: TimeInterval = 3, maxWait: TimeInterval = 30, action: @escaping () -> Void) {
        self.quiet = quiet
        self.maxWait = maxWait
        self.action = action
    }

    public func poke() {
        queue.async {
            let now = Date()
            if self.firstEvent == nil { self.firstEvent = now }
            self.work?.cancel()
            let elapsed = now.timeIntervalSince(self.firstEvent!)
            let delay = max(0, min(self.quiet, self.maxWait - elapsed))
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.firstEvent = nil
                self.action()
            }
            self.work = item
            self.queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    public func cancel() { queue.async { self.work?.cancel(); self.firstEvent = nil } }
}

#if os(macOS)
public final class FSEventsWatcher: FolderWatcher {
    let root: URL
    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?

    public init(root: URL) { self.root = root.resolvingSymlinksInPath() }

    public func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = list.prefix(count).contains { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }
            if relevant { me.onChange?() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "gitstick.fsevents"))
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
#endif

/// Portable fallback (Linux, tests): compares a cheap snapshot of the tree every `interval`.
public final class PollingWatcher: FolderWatcher {
    let root: URL
    let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var last: [String: Date] = [:]

    public init(root: URL, interval: TimeInterval = 2) {
        self.root = root
        self.interval = interval
    }

    func snapshot() -> [String: Date] {
        var out: [String: Date] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return out }
        for case let url as URL in e {
            if url.lastPathComponent == ".git" { e.skipDescendants(); continue }
            out[url.path] = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
        }
        return out
    }

    public func start(onChange: @escaping () -> Void) {
        stop()
        last = snapshot()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "gitstick.poll"))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.snapshot()
            if now != self.last { self.last = now; onChange() }
        }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }
    deinit { stop() }
}
