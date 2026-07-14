import Foundation
import IOKit
import IOKit.pwr_mgt

final class Netafuri {
    private var sleepAssertionID: IOPMAssertionID = 0
    private var lidWasClosed = false
    private var lidTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []

    func run() {
        print("netafuri - pretending to sleep")
        print("  lid close -> lock + display off + prevent sleep")
        print("  Ctrl+C to quit")
        print("")

        preventSleep()

        lidWasClosed = isClamshellClosed()
        if lidWasClosed {
            print("[info] lid is currently closed")
        }

        setupSignalHandlers()
        startLidMonitor()

        print("[ready] monitoring lid state...")
        dispatchMain()
    }

    // MARK: - Sleep Prevention

    private func preventSleep() {
        let result = IOPMAssertionCreateWithName(
            "PreventSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "netafuri: keeping system awake on lid close" as CFString,
            &sleepAssertionID
        )
        if result == kIOReturnSuccess {
            print("[ok] sleep prevention active")
        } else {
            print("[warn] could not create sleep assertion - try running with sudo")
        }
    }

    // MARK: - Lid Monitoring

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
        print("[event] lid closed -> locking screen & blanking display")
        lockScreen()
        blankDisplay()
    }

    private func onLidOpen() {
        print("[event] lid opened")
    }

    // MARK: - Lock Screen (private API)

    private func lockScreen() {
        let paths = [
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            "/System/Library/PrivateFrameworks/login.framework/login",
        ]

        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            defer { dlclose(handle) }

            guard let sym = dlsym(handle, "SACLockScreenImmediate") else { continue }

            typealias LockFunc = @convention(c) () -> Void
            let lock = unsafeBitCast(sym, to: LockFunc.self)
            lock()
            print("  [ok] screen locked")
            return
        }

        print("  [warn] could not lock screen (SACLockScreenImmediate unavailable)")
    }

    // MARK: - Display Blanking

    private func blankDisplay() {
        if blankViaDisplayWrangler() {
            print("  [ok] display blanked (IODisplayWrangler)")
            return
        }

        if blankViaPmset() {
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

    private func blankViaPmset() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            print("[ok] sleep assertion released")
        }
        exit(0)
    }
}

let app = Netafuri()
app.run()
