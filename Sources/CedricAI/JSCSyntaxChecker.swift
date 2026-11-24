import Foundation
import JavaScriptCore
import CedricCore

/// JavaScript syntax for edit validation (`OwlEditValidation`), with
/// JavaScriptCore's syntax check only (JSCheckScriptSyntax): the script is
/// parsed, never run. A fresh, empty context per check; no global object
/// is set up, no callbacks are installed, and the context is released at
/// once. The only property read is the syntax error's own `line`.
public struct JSCSyntaxChecker: OwlScriptSyntaxChecker {
    public init() {}

    public func syntaxError(in script: String) -> OwlSyntaxError? {
        guard let ctx = JSGlobalContextCreate(nil) else { return nil }
        defer { JSGlobalContextRelease(ctx) }
        let source = JSStringCreateWithCFString(script as CFString)
        defer { JSStringRelease(source) }
        var exception: JSValueRef?
        if JSCheckScriptSyntax(ctx, source, nil, 1, &exception) { return nil }
        guard let exception else { return OwlSyntaxError(message: String(localized: "not valid JavaScript")) }
        var message = String(localized: "not valid JavaScript")
        if let s = JSValueToStringCopy(ctx, exception, nil) {
            message = JSStringCopyCFString(kCFAllocatorDefault, s) as String
            JSStringRelease(s)
        }
        var line: Int?
        if JSValueIsObject(ctx, exception), let object = JSValueToObject(ctx, exception, nil) {
            let name = JSStringCreateWithUTF8CString("line")
            defer { JSStringRelease(name) }
            let value = JSObjectGetProperty(ctx, object, name, nil)
            if let value, JSValueIsNumber(ctx, value) {
                let n = JSValueToNumber(ctx, value, nil)
                if n.isFinite, n >= 1 { line = Int(n) }
            }
        }
        if message.hasPrefix("SyntaxError: ") { message.removeFirst("SyntaxError: ".count) }
        return OwlSyntaxError(message: String(message.prefix(160)), line: line)
    }
}
