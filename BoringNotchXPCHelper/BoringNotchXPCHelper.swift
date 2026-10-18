//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import AppKit
import ApplicationServices
import IOKit
import Compression
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Browser tabs

    /// Finds the tab whose title best matches `title` and selects it; `raise` also brings its window to the front.
    @objc func activateBrowserTab(_ bundleIdentifier: String, matching title: String, raise: Bool, with reply: @escaping (Bool) -> Void) {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, let axApp = browserElement(for: bundleIdentifier) else {
            reply(false)
            return
        }

        var best: (tab: AXUIElement, window: AXUIElement, score: Double)?
        for (window, tabs) in browserTabs(axApp) {
            for tab in tabs {
                let score = matchScore(needle: needle, label: tab.label.lowercased())
                if score > (best?.score ?? 0) {
                    best = (tab.element, window, score)
                }
            }
        }

        guard let best, best.score >= 0.6 else {
            reply(false)
            return
        }
        AXUIElementPerformAction(best.tab, kAXPressAction as CFString)
        if raise {
            AXUIElementPerformAction(best.window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(best.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        reply(true)
    }

    /// The page's player pause button, recognised by its label (players label it "Pause", "Пауза (k)" etc.)
    private func findPauseButton(in window: AXUIElement) -> AXUIElement? {
        let labels = ["пауза", "pause", "приостановить"]
        var visited = 0
        func search(_ element: AXUIElement, depth: Int, inPage: Bool) -> AXUIElement? {
            guard depth < 40, visited < 8000 else { return nil }
            visited += 1
            let role = axString(element, kAXRoleAttribute)
            let page = inPage || role == "AXWebArea"
            if page, role == kAXButtonRole as String {
                let label = (axString(element, kAXDescriptionAttribute) ?? axString(element, kAXTitleAttribute) ?? "").lowercased()
                if labels.contains(where: { label.hasPrefix($0) }) {
                    return element
                }
            }
            for child in axElements(element, kAXChildrenAttribute) {
                if let found = search(child, depth: depth + 1, inPage: page) {
                    return found
                }
            }
            return nil
        }
        return search(window, depth: 0, inPage: false)
    }

    /// Tabs that show a sound indicator, in tab order, as JSON `[{"title", "host", "icon"}]`;
    /// `icon` is the tab's favicon data URL when the browser's session file provides it.
    @objc func listAudioTabs(_ bundleIdentifier: String, with reply: @escaping (Data) -> Void) {
        guard let axApp = browserElement(for: bundleIdentifier) else {
            reply(Data("[]".utf8))
            return
        }
        let audioTabs = browserTabs(axApp).flatMap { $0.tabs }.filter { $0.hasAudio }
        let session = bundleIdentifier == "org.mozilla.firefox" ? firefoxSessionTabs() : []

        let result: [[String: String]] = audioTabs.map { tab in
            let label = tab.label.lowercased()
            let entry = session.max { matchScore(needle: $0.title.lowercased(), label: label) < matchScore(needle: $1.title.lowercased(), label: label) }
            let matched = entry.flatMap { matchScore(needle: $0.title.lowercased(), label: label) >= 0.8 ? $0 : nil }
            return [
                "title": tab.label,
                "host": matched.flatMap { URL(string: $0.url)?.host } ?? "",
                "icon": matched?.icon ?? "",
            ]
        }
        reply((try? JSONSerialization.data(withJSONObject: result)) ?? Data("[]".utf8))
    }

    /// Pause buttons pressed per tab, pressed again to resume (they turn into "Play" once pressed)
    private var pausedPlayerButtons: [String: AXUIElement] = [:]

    /// Pauses or resumes the player in the matching tab: 1 paused, 0 resumed, -1 no player found.
    @objc func toggleBrowserTabPlayback(_ bundleIdentifier: String, matching title: String, with reply: @escaping (Int) -> Void) {
        activateBrowserTab(bundleIdentifier, matching: title, raise: false) { [self] selected in
            guard selected, let axApp = browserElement(for: bundleIdentifier) else {
                reply(-1)
                return
            }
            if let button = pausedPlayerButtons.removeValue(forKey: title),
               AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                reply(0)
                return
            }
            // The page of a just-selected tab needs a moment to appear in the tree
            for _ in 0..<6 {
                for window in axElements(axApp, kAXWindowsAttribute) {
                    if let button = findPauseButton(in: window) {
                        AXUIElementPerformAction(button, kAXPressAction as CFString)
                        pausedPlayerButtons[title] = button
                        reply(1)
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            reply(-1)
        }
    }

    private struct SessionTab {
        let title: String
        let url: String
        let icon: String
    }

    /// Open tabs from Firefox's session file (mozLz4: magic, 4-byte size, then a raw LZ4 block).
    private func firefoxSessionTabs() -> [SessionTab] {
        let profiles = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
        let files = ((try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("sessionstore-backups/recovery.jsonlz4") }
        let newest = files.max {
            let date: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            return date($0) < date($1)
        }
        guard let newest, let data = try? Data(contentsOf: newest), data.count > 12,
              data.prefix(8) == Data("mozLz40\0".utf8) else { return [] }

        let size = data[8...11].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var decoded = Data(count: size)
        let written = decoded.withUnsafeMutableBytes { dst in
            data.dropFirst(12).withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count - 12,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written > 0,
              let json = try? JSONSerialization.jsonObject(with: decoded.prefix(written)) as? [String: Any] else { return [] }

        let windows = json["windows"] as? [[String: Any]] ?? []
        return windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }.compactMap { tab in
            let entries = tab["entries"] as? [[String: Any]] ?? []
            let index = (tab["index"] as? Int ?? entries.count) - 1
            guard entries.indices.contains(index), let title = entries[index]["title"] as? String else { return nil }
            return SessionTab(title: title, url: entries[index]["url"] as? String ?? "", icon: tab["image"] as? String ?? "")
        }
    }

    private struct BrowserTab {
        let element: AXUIElement
        let label: String
        let hasAudio: Bool
    }

    /// The accessibility element of a running browser, with its full tree switched on.
    private func browserElement(for bundleIdentifier: String) -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              let appURL = app.bundleURL, let webURL = URL(string: "https://example.com"),
              NSWorkspace.shared.urlsForApplications(toOpen: webURL).contains(appURL) else {
            // Only browsers have tabs worth searching
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        // Firefox only exposes its tab strip once an assistive client asks for it (as VoiceOver does)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return axApp
    }

    private func browserTabs(_ axApp: AXUIElement) -> [(window: AXUIElement, tabs: [BrowserTab])] {
        axElements(axApp, kAXWindowsAttribute).map { window in
            var tabs: [BrowserTab] = []
            // The tree may still be building right after it was switched on
            for _ in 0..<8 {
                collectTabs(in: window, depth: 0, into: &tabs)
                if !tabs.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return (window, tabs)
        }
    }

    /// 1 when the label contains the whole title, otherwise the share of the title's words found in the label.
    private func matchScore(needle: String, label: String) -> Double {
        if label.contains(needle) { return 1 }
        let words: (String) -> Set<String> = { text in
            Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 })
        }
        let needleWords = words(needle)
        guard !needleWords.isEmpty else { return 0 }
        return Double(needleWords.intersection(words(label)).count) / Double(needleWords.count)
    }

    private func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func collectTabs(in element: AXUIElement, depth: Int, into tabs: inout [BrowserTab]) {
        guard depth < 12 else { return }
        let role = axString(element, kAXRoleAttribute)
        // Page content can be huge and never contains the tab strip
        if role == "AXWebArea" { return }

        if role == kAXRadioButtonRole as String || axString(element, kAXSubroleAttribute) == "AXTabButton" {
            let label = axString(element, kAXTitleAttribute) ?? axString(element, kAXDescriptionAttribute) ?? ""
            if !label.isEmpty {
                // Firefox adds a sound indicator button ("main-button") to tabs that play audio
                let hasAudio = axElements(element, kAXChildrenAttribute).contains {
                    axString($0, "AXDOMIdentifier") == "main-button"
                }
                tabs.append(BrowserTab(element: element, label: label, hasAudio: hasAudio))
            }
            return
        }

        for child in axElements(element, kAXChildrenAttribute) {
            collectTabs(in: child, depth: depth + 1, into: &tabs)
        }
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}
