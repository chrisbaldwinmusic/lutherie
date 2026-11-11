import Foundation
import PedalUI

// The extension's entry point is NSExtensionMain (set in Package.swift). These references keep the
// plugin classes linked in so the system can find them by name from Info.plist.

public func lutherieKeepClasses() -> [AnyClass] {
    [LutherieViewController.self, LutherieAudioUnit.self]
}
