// What the wizard needs from macOS and from the rest of the app, as plain closures so previews and
// screenshots never touch real permission prompts.
import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import SusuCore

public enum MicPermission: Sendable, Equatable { case notDetermined, granted, denied }

/// Numbers of the Wispr dry run (spec 1.6 «Первый запуск», step 4).
public struct WisprPreview: Sendable, Equatable {
    public var dictations: Int
    public var audioFiles: Int
    public var vocabulary: Int
    public var styleGroups: Int
    public var calls: Int
    public var notes: Int
    public var neededBytes: Int64
    public var freeBytes: Int64
    public init(dictations: Int = 0, audioFiles: Int = 0, vocabulary: Int = 0, styleGroups: Int = 0, calls: Int = 0,
                notes: Int = 0, neededBytes: Int64 = 0, freeBytes: Int64 = 0) {
        self.dictations = dictations; self.audioFiles = audioFiles; self.vocabulary = vocabulary
        self.styleGroups = styleGroups; self.calls = calls; self.notes = notes
        self.neededBytes = neededBytes; self.freeBytes = freeBytes
    }
}

/// Hooks the app wires to the real modules. nil = not wired yet; the wizard says so honestly.
public struct OnboardingHooks: Sendable {
    /// Downloads GigaAM (230 MB), reporting progress 0...1.
    public var downloadGigaAM: (@Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void)?
    /// Counts what a Wispr import would bring. nil result = nothing to import.
    public var wisprDryRun: (@Sendable () async -> WisprPreview?)?
    /// Runs the import (`includeAudio` false when disk space is short), reporting progress 0...1.
    public var wisprImport: (@Sendable (_ includeAudio: Bool, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void)?
    public init() {}
}

struct OnboardingSystem {
    var micPermission: () -> MicPermission
    var requestMic: () async -> Bool
    var axTrusted: () -> Bool
    var promptAX: () -> Void
    var open: (URL) -> Void
    var wisprFolderExists: () -> Bool

    static let micPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let axPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let keyboardPane = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    static var live: OnboardingSystem { OnboardingSystem(
        micPermission: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        },
        requestMic: { await AVCaptureDevice.requestAccess(for: .audio) },
        axTrusted: { AXIsProcessTrusted() },
        promptAX: {
            let key = "AXTrustedCheckOptionPrompt" as CFString   // kAXTrustedCheckOptionPrompt, spelled out for Swift 6
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        },
        open: { NSWorkspace.shared.open($0) },
        wisprFolderExists: {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")
            return FileManager.default.fileExists(atPath: url.path)
        })
    }
}
