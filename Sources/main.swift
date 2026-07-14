import AppKit
import IOKit
import IOKit.pwr_mgt
import Security

// iokit_common_msg(x) = 0xe0000000 | x
private let kMsgCanSystemSleep:  UInt32 = 0xe0000270
private let kMsgSystemWillSleep: UInt32 = 0xe0000280

private let sudoersPath = "/etc/sudoers.d/moonveil"
private let sudoersRule = "%admin ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1\n"

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var active = false

    private var rootPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var lidWasClosed = false
    private var lidTimer: DispatchSourceTimer?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        lidWasClosed = isClamshellClosed()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if active { deactivate() }
    }

    // MARK: - Menu Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Enable", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name = active ? "moon.zzz.fill" : "moon.zzz"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "moonveil")
        image?.isTemplate = true
        button.image = image
    }

    // MARK: - Toggle

    @objc private func toggle() {
        if active {
            deactivate()
        } else {
            activate()
        }
    }

    @objc private func quitApp() {
        if active { deactivate() }
        NSApp.terminate(nil)
    }

    // MARK: - Activate / Deactivate

    private func activate() {
        guard !active else { return }
        guard setDisableSleep(true) else { return }

        registerPowerCallbacks()
        startLidMonitor()

        active = true
        toggleItem.title = "Disable"
        updateIcon()
    }

    private func deactivate() {
        guard active else { return }

        lidTimer?.cancel()
        lidTimer = nil

        if rootPort != 0 {
            IODeregisterForSystemPower(&powerNotifier)
            rootPort = 0
            powerNotifier = 0
        }
        if let port = powerNotifyPort {
            IONotificationPortDestroy(port)
            powerNotifyPort = nil
        }

        setDisableSleep(false)

        active = false
        toggleItem.title = "Enable"
        updateIcon()
    }

    // MARK: - Privileged Execution

    @discardableResult
    private func setDisableSleep(_ disable: Bool) -> Bool {
        let value = disable ? "1" : "0"

        if sudoNonInteractive(["pmset", "disablesleep", value]) {
            return true
        }

        guard installSudoersRule() else { return false }

        return sudoNonInteractive(["pmset", "disablesleep", value])
    }

    private func sudoNonInteractive(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n"] + args
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

    private func installSudoersRule() -> Bool {
        let tmpPath = NSTemporaryDirectory() + "moonveil_sudoers"
        guard FileManager.default.createFile(
            atPath: tmpPath,
            contents: sudoersRule.data(using: .utf8)
        ) else { return false }

        let cmd = "/usr/sbin/visudo -c -f \(tmpPath) 2>/dev/null && " +
            "cp \(tmpPath) \(sudoersPath) && " +
            "chown root:wheel \(sudoersPath) && " +
            "chmod 0440 \(sudoersPath) && " +
            "rm -f \(tmpPath)"
        return runPrivileged(cmd)
    }

    private func runPrivileged(_ command: String) -> Bool {
        // AuthorizationCreate shows the macOS auth dialog with Touch ID support
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let auth = authRef else { return false }
        defer { AuthorizationFree(auth, [.destroyRights]) }

        let rightName = strdup("system.privilege.admin")!
        defer { free(rightName) }
        var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]

        let copyStatus = withUnsafeMutablePointer(to: &item) { ptr in
            var rights = AuthorizationRights(count: 1, items: ptr)
            return AuthorizationCopyRights(auth, &rights, nil, flags, nil)
        }
        guard copyStatus == errAuthorizationSuccess else { return false }

        // AuthorizationExecuteWithPrivileges is deprecated but still present in dylib
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "AuthorizationExecuteWithPrivileges") else {
            return runPrivilegedAppleScript(command)
        }

        typealias AuthExecFn = @convention(c) (
            AuthorizationRef,
            UnsafePointer<CChar>,
            AuthorizationFlags,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
            UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
        ) -> OSStatus

        let authExec = unsafeBitCast(sym, to: AuthExecFn.self)

        let cArg0 = strdup("-c")!
        let cArg1 = strdup(command)!
        defer { free(cArg0); free(cArg1) }
        var args: [UnsafeMutablePointer<CChar>?] = [cArg0, cArg1, nil]

        var pipe: UnsafeMutablePointer<FILE>?
        let execStatus = authExec(auth, "/bin/sh", [], &args, &pipe)

        if let pipe = pipe {
            while fgetc(pipe) != EOF {}
            fclose(pipe)
        }
        var childStatus: Int32 = 0
        wait(&childStatus)

        return execStatus == errAuthorizationSuccess
    }

    private func runPrivilegedAppleScript(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: - Power Callbacks (veto sleep requests)

    private func registerPowerCallbacks() {
        let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
            guard let refcon = refcon else { return }
            let d = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            d.handlePowerEvent(messageType, argument: messageArgument)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            selfPtr,
            &powerNotifyPort,
            callback,
            &powerNotifier
        )

        guard rootPort != 0, let port = powerNotifyPort else { return }

        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func handlePowerEvent(_ messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let id = Int(bitPattern: argument)
        switch messageType {
        case kMsgCanSystemSleep:
            IOCancelPowerChange(rootPort, id)
        case kMsgSystemWillSleep:
            IOAllowPowerChange(rootPort, id)
        default:
            break
        }
    }

    // MARK: - Lid Monitoring

    private func startLidMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
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
        ) else { return false }

        return (prop.takeRetainedValue() as? Bool) ?? false
    }

    // MARK: - Lid Events

    private func onLidClose() {
        lockScreen()
        usleep(300_000)
        blankDisplay()
    }

    private func onLidOpen() {}

    // MARK: - Lock Screen

    private func lockScreen() {
        let paths = [
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            "/System/Library/PrivateFrameworks/login.framework/login",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY),
                  let sym = dlsym(handle, "SACLockScreenImmediate") else { continue }

            typealias LockFunc = @convention(c) () -> Void
            unsafeBitCast(sym, to: LockFunc.self)()
            return
        }

        let cgSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        if FileManager.default.fileExists(atPath: cgSessionPath) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cgSessionPath)
            p.arguments = ["-suspend"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: - Display Blanking

    private func blankDisplay() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayWrangler")
        )
        if service != 0 {
            IORegistryEntrySetCFProperty(service, "IORequestIdle" as CFString, kCFBooleanTrue)
            IOObjectRelease(service)
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
