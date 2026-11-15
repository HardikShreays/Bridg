import Foundation

// Entry point of the share extension binary.
//
// The .appex executable is launched directly by macOS's extension host, which
// hands the extension context over the command line. Foundation's extension
// runtime then instantiates the principal class named in Info.plist
// (NSExtensionPrincipalClass) and calls beginRequest on it. `NSExtensionMain`
// is not exposed in the Swift overlay, so declare the C symbol directly —
// this mirrors what Xcode-built app extensions link against.
@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32

_ = NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
