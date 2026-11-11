import AppKit
import Foundation

/// Installs the VST3 plugin that ships inside the app, and makes sure the Audio Unit is registered,
/// so no separate installer script is needed.
enum PluginInstaller {
    static var vst3Folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3")
    }
    static var installedVST3: URL { vst3Folder.appendingPathComponent("Lutherie.vst3") }
    static var bundledZip: URL? { Bundle.main.url(forResource: "Lutherie-vst3", withExtension: "zip") }
    static let stampKey = "installedVST3Stamp"

    /// A fingerprint of the bundled plugin, so it's only copied again after an update.
    static var bundledStamp: String? {
        guard let zip = bundledZip, let a = try? FileManager.default.attributesOfItem(atPath: zip.path) else { return nil }
        return "\(a[.size] ?? 0)-\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    /// Runs at launch: installs or updates the plugins when needed. Returns a message to show, if any.
    @discardableResult
    static func installIfNeeded(force: Bool = false) -> String? {
        registerAudioUnit()
        guard let zip = bundledZip, let stamp = bundledStamp else { return nil }
        let fm = FileManager.default
        let upToDate = fm.fileExists(atPath: installedVST3.path) && UserDefaults.standard.string(forKey: stampKey) == stamp
        if upToDate && !force { return nil }
        do {
            try fm.createDirectory(at: vst3Folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedVST3.path) { try fm.trashItem(at: installedVST3, resultingItemURL: nil) }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, vst3Folder.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0, fm.fileExists(atPath: installedVST3.path) else {
                return "Lutherie couldn't install its VST3 plugin (unzip failed)."
            }
            clearQuarantine(installedVST3)
            UserDefaults.standard.set(stamp, forKey: stampKey)
            return "Plugins are ready: Lutherie is now available as an Audio Unit and as a VST3 in your music software. If it's already open, rescan its plugins."
        } catch {
            return "Lutherie couldn't install its VST3 plugin: \(error.localizedDescription)"
        }
    }

    /// Files copied out of a downloaded app keep the "downloaded" flag; remove it from the plugin.
    static func clearQuarantine(_ url: URL) {
        let fm = FileManager.default
        var paths = [url.path]
        if let e = fm.enumerator(atPath: url.path) { while let p = e.nextObject() as? String { paths.append(url.appendingPathComponent(p).path) } }
        for p in paths { removexattr(p, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    /// The Audio Unit lives inside the app; telling the system about it makes hosts list it right away.
    static func registerAudioUnit() {
        guard let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("LutherieAU.appex"),
              FileManager.default.fileExists(atPath: appex.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-a", appex.path]
        try? p.run()
    }

    /// Where the app is running from, so it can suggest moving into Applications.
    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }
}
