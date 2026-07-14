import Foundation
import IOKit
import IOKit.pwr_mgt

// iokit_common_msg(x) = 0xe0000000 | x
private let kMsgCanSystemSleep:  UInt32 = 0xe0000270
private let kMsgSystemWillSleep: UInt32 = 0xe0000280

final class Netafuri {
    private var rootPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var lidWasClosed = false
    private var lidTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []

    func run() {
        print("netafuri - pretending to sleep")
        print("  lid close -> lock + display off + prevent sleep")
        print("  Ctrl+C to quit")
        print("")

        if !pmset(["disablesleep", "1"]) {
            print("[error] pmset disablesleep 1 failed")
            print("  try: make run-sudo")
            exit(1)
        }
        print("[ok] sleep disabled (pmset)")

        registerPowerCallbacks()

        lidWasClosed = isClamshellClosed()
        if lidWasClosed {
            print("[info] lid is currently closed")
        }

        setupSignalHandlers()
        startLidMonitor()

        print("[ready] monitoring lid state...")
        dispatchMain()
    }

    // MARK: - pmset

    @discardableResult
    private func pmset(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Power Callbacks (veto sleep requests)

    private func registerPowerCallbacks() {
        let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
            guard let refcon = refcon else { return }
            let app = Unmanaged<Netafuri>.fromOpaque(refcon).takeUnretainedValue()
            app.handlePowerEvent(messageType, argument: messageArgument)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            selfPtr,
            &powerNotifyPort,
            callback,
            &powerNotifier
        )

        guard rootPort != 0, let port = powerNotifyPort else {
            print("[warn] could not register power callbacks")
            return
        }

        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        print("[ok] power event callbacks registered")
    }

    private func handlePowerEvent(_ messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case kMsgCanSystemSleep:
            IOCancelPowerChange(rootPort, notificationID)
        case kMsgSystemWillSleep:
            IOAllowPowerChange(rootPort, notificationID)
        default:
            break
        }
    }

    // MARK: - Lid Monitoring (poll AppleClamshellState)
    // IOKit notification for clamshell state change does not fire
    // when disablesleep is active, so we poll the property instead.

    private func startLidMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.pollLidState()
        }
        timer.resume()
        lidTimer = timer
    }

    private func pollLidState() {
        let closed = isClamshellClosed()
        if closed && !lidWasClosed {
            onLidClose()
        } else if !closed && lidWasClosed {
            onLidOpen()
        }
        lidWasClosed = closed
    }

    private func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        guard let prop = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return false
        }

        return (prop.takeRetainedValue() as? Bool) ?? false
    }

    // MARK: - Lid Events

    private func onLidClose() {
        print("[event] lid closed -> locking & blanking")
        lockScreen()
        usleep(300_000)
        blankDisplay()
    }

    private func onLidOpen() {
        print("[event] lid opened")
    }

    // MARK: - Lock Screen

    private func lockScreen() {
        let frameworkPaths = [
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            "/System/Library/PrivateFrameworks/login.framework/login",
        ]

        for path in frameworkPaths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            defer { dlclose(handle) }
            guard let sym = dlsym(handle, "SACLockScreenImmediate") else { continue }

            typealias LockFunc = @convention(c) () -> Void
            let lock = unsafeBitCast(sym, to: LockFunc.self)
            lock()
            print("  [ok] screen locked (SACLockScreenImmediate)")
            return
        }

        let cgSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        if FileManager.default.fileExists(atPath: cgSessionPath) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cgSessionPath)
            p.arguments = ["-suspend"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    print("  [ok] screen locked (CGSession)")
                    return
                }
            }
        }

        print("  [warn] could not lock screen")
    }

    // MARK: - Display Blanking

    private func blankDisplay() {
        if blankViaDisplayWrangler() {
            print("  [ok] display blanked (IODisplayWrangler)")
            return
        }

        if pmset(["displaysleepnow"]) {
            print("  [ok] display blanked (pmset)")
            return
        }

        print("  [warn] could not blank display")
    }

    private func blankViaDisplayWrangler() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayWrangler")
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        let result = IORegistryEntrySetCFProperty(
            service,
            "IORequestIdle" as CFString,
            kCFBooleanTrue
        )
        return result == kIOReturnSuccess
    }

    // MARK: - Signal Handling

    private func setupSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for sig: Int32 in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdown()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown() {
        print("\n[exit] shutting down...")
        pmset(["disablesleep", "0"])
        print("[ok] sleep re-enabled (pmset)")
        if rootPort != 0 {
            IODeregisterForSystemPower(&powerNotifier)
        }
        if let port = powerNotifyPort {
            IONotificationPortDestroy(port)
        }
        exit(0)
    }
}

let app = Netafuri()
app.run()
