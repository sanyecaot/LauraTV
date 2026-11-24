import Foundation
import SwiftUI

public typealias STTranslationCallback = @convention(c) (NSString) -> NSString

private var _registeredCallback: STTranslationCallback?

@_cdecl("STRegisterSwiftUICallback")
public func STRegisterSwiftUICallback(_ callback: @escaping STTranslationCallback) {
    _registeredCallback = callback
}

@inline(__always)
private func translateSwiftUIString(_ raw: String) -> String {
    guard !raw.isEmpty, let cb = _registeredCallback else {
        return raw
    }
    let nsInput = raw as NSString
    let nsOutput = cb(nsInput)
    return nsOutput as String
}

/// Bridge helpers for SwiftUI LocalizedStringKey & Text initializers
@_cdecl("STTranslateSwiftUIKey")
public func STTranslateSwiftUIKey(_ key: NSString) -> NSString {
    guard let cb = _registeredCallback else { return key }
    return cb(key)
}

public enum SideStoreSwiftUIBridge {
    public static func localizedText(_ key: String) -> Text {
        let translated = translateSwiftUIString(key)
        return Text(verbatim: translated)
    }
}
