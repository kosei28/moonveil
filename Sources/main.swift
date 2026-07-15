import AppKit
import IOKit
import IOKit.pwr_mgt
import ServiceManagement

// iokit_common_msg(x) = 0xe0000000 | x
private let kMsgCanSystemSleep:  UInt32 = 0xe0000270
private let kMsgSystemWillSleep: UInt32 = 0xe0000280

private let sudoersPath = "/etc/sudoers.d/moonveil"
private let sudoersRule = "%admin ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1\n"

enum LidAction: Int {
    case lockScreen = 0
    case clamshell = 1
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var lockScreenItem: NSMenuItem!
    private var clamshellItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var capsLockToggleItem: NSMenuItem!
    private var active = false
    private var lidAction: LidAction = .lockScreen

    private var rootPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var lidWasClosed = false
    private var lidTimer: DispatchSourceTimer?
    private var screenCountBeforeLidClose = 0

    private var capsLockToggleEnabled = false
    private var eventTap: CFMachPort?
    private var permissionItem: NSMenuItem!
    private var permissionTimer: DispatchSourceTimer?
    private var hidManager: IOHIDManager?
    private var ledTimer: DispatchSourceTimer?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let saved = LidAction(rawValue: UserDefaults.standard.integer(forKey: "lidAction")) {
            lidAction = saved
        }
        setupStatusItem()
        lidWasClosed = isClamshellClosed()

        if UserDefaults.standard.bool(forKey: "capsLockToggle") {
            enableCapsLockToggle()
        }

        if UserDefaults.standard.bool(forKey: "enabled") {
            activate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if active { deactivate() }
        if capsLockToggleEnabled { disableCapsLockToggle() }
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

        lockScreenItem = NSMenuItem(title: "Lock Screen", action: #selector(selectLockScreen), keyEquivalent: "")
        lockScreenItem.target = self
        menu.addItem(lockScreenItem)

        clamshellItem = NSMenuItem(title: "Clamshell", action: #selector(selectClamshell), keyEquivalent: "")
        clamshellItem.target = self
        menu.addItem(clamshellItem)

        updateModeMenu()

        menu.addItem(.separator())

        capsLockToggleItem = NSMenuItem(title: "Use CapsLock to Toggle", action: #selector(toggleCapsLockMode), keyEquivalent: "")
        capsLockToggleItem.target = self
        capsLockToggleItem.state = capsLockToggleEnabled ? .on : .off
        menu.addItem(capsLockToggleItem)

        permissionItem = NSMenuItem(title: "⚠ Grant Accessibility Permission…", action: #selector(requestAccessibility), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isHidden = true
        menu.addItem(permissionItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

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
            UserDefaults.standard.set(false, forKey: "enabled")
        } else {
            activate()
            if active { UserDefaults.standard.set(true, forKey: "enabled") }
        }
    }

    @objc private func selectLockScreen() {
        lidAction = .lockScreen
        UserDefaults.standard.set(lidAction.rawValue, forKey: "lidAction")
        updateModeMenu()
    }

    @objc private func selectClamshell() {
        lidAction = .clamshell
        UserDefaults.standard.set(lidAction.rawValue, forKey: "lidAction")
        updateModeMenu()
    }

    private func updateModeMenu() {
        lockScreenItem.state = lidAction == .lockScreen ? .on : .off
        clamshellItem.state = lidAction == .clamshell ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                loginItem.state = .off
            } else {
                try SMAppService.mainApp.register()
                loginItem.state = .on
            }
        } catch {}
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
        if capsLockToggleEnabled { setCapsLockLED(on: true) }
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
        if capsLockToggleEnabled { setCapsLockLED(on: false) }
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
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: - CapsLock Toggle

    private let capsLockHIDSrc = 0x700000039
    private let f18HIDDst = 0x70000006D
    private let kVK_F18: Int64 = 0x4F

    @objc private func toggleCapsLockMode() {
        if capsLockToggleEnabled {
            disableCapsLockToggle()
        } else {
            enableCapsLockToggle()
        }
        UserDefaults.standard.set(capsLockToggleEnabled, forKey: "capsLockToggle")
    }

    private func enableCapsLockToggle() {
        guard !capsLockToggleEnabled else { return }

        capsLockToggleEnabled = true
        capsLockToggleItem?.state = .on

        if !AXIsProcessTrusted() {
            requestAccessibility()
            permissionItem?.isHidden = false
            startPermissionPolling()
            return
        }

        activateCapsLockTap()
    }

    private func activateCapsLockTap() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let d = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            return d.handleCapsLockEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else { return }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        openHIDManager()
        setCapsLockRemapping(enabled: true)
        setCapsLockLED(on: active)

        startLEDTimer()
    }

    private func startLEDTimer() {
        guard ledTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.setCapsLockLED(on: self.active)
        }
        timer.resume()
        ledTimer = timer
    }

    private func stopLEDTimer() {
        ledTimer?.cancel()
        ledTimer = nil
    }

    private func openHIDManager() {
        if let old = hidManager {
            IOHIDManagerClose(old, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let filter = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as NSDictionary
        IOHIDManagerSetDeviceMatching(manager, filter)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            let d = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            d.setCapsLockLED(on: d.active)
        }, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
    }

    private func disableCapsLockToggle() {
        guard capsLockToggleEnabled else { return }

        stopPermissionPolling()
        stopLEDTimer()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }

        setCapsLockRemapping(enabled: false)
        let osCapslockOn = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
        setCapsLockLED(on: osCapslockOn)

        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }

        capsLockToggleEnabled = false
        capsLockToggleItem?.state = .off
        permissionItem?.isHidden = true
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.stopPermissionPolling()
                self.permissionItem?.isHidden = true
                self.activateCapsLockTap()
            }
        }
        timer.resume()
        permissionTimer = timer
    }

    private func stopPermissionPolling() {
        permissionTimer?.cancel()
        permissionTimer = nil
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func handleCapsLockEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == kVK_F18 else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            DispatchQueue.main.async { [weak self] in
                self?.toggle()
            }
        }

        return nil
    }

    // MARK: - CapsLock Key Remapping

    private func setCapsLockRemapping(enabled: Bool) {
        var mappings = readHIDKeyMappings().filter { $0["HIDKeyboardModifierMappingSrc"] != capsLockHIDSrc }

        if enabled {
            mappings.append([
                "HIDKeyboardModifierMappingSrc": capsLockHIDSrc,
                "HIDKeyboardModifierMappingDst": f18HIDDst,
            ])
        }

        writeHIDKeyMappings(mappings)
    }

    private func readHIDKeyMappings() -> [[String: Int]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--get", "UserKeyMapping"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let array = plist as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict in
            guard let src = dict["HIDKeyboardModifierMappingSrc"] as? Int,
                  let dst = dict["HIDKeyboardModifierMappingDst"] as? Int else { return nil }
            return ["HIDKeyboardModifierMappingSrc": src, "HIDKeyboardModifierMappingDst": dst]
        }
    }

    private func writeHIDKeyMappings(_ mappings: [[String: Int]]) {
        let payload: [String: Any] = ["UserKeyMapping": mappings.map { $0 as [String: Any] }]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", jsonString]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - CapsLock LED

    private func setCapsLockLED(on: Bool) {
        guard let manager = hidManager,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }

        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(
                device,
                [kIOHIDElementUsagePageKey: kHIDPage_LEDs,
                 kIOHIDElementUsageKey: kHIDUsage_LED_CapsLock] as CFDictionary,
                IOOptionBits(kIOHIDOptionsTypeNone)
            ) as? [IOHIDElement], let element = elements.first else { continue }

            let value = IOHIDValueCreateWithIntegerValue(
                kCFAllocatorDefault,
                element,
                0,
                on ? 1 : 0
            )
            IOHIDDeviceSetValue(device, element, value)
        }
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
        if !closed {
            screenCountBeforeLidClose = NSScreen.screens.count
        }
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
        let hasExternalDisplay = screenCountBeforeLidClose > 1
        if lidAction == .clamshell && hasExternalDisplay {
            return
        }
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
