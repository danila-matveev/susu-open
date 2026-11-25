// settings.json model (spec 1.3, 1.6, 4.3). No keys here: secrets live in SecretStore.
// Every field decodes with a default, and unknown top-level fields survive a round trip.
import Foundation

/// Minimal JSON tree used to carry fields this version does not know about.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public enum HotkeyModifier: String, Codable, Sendable, CaseIterable {
    case control, option, command, shift
}

/// A physical modifier key on its own (left/right matter).
public enum ModifierKey: String, Codable, Sendable, CaseIterable {
    case leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand, leftShift, rightShift, fn
}

/// Either a lone modifier key (`modifierKey`) or a key code with modifiers. The Hotkey module maps it.
public struct HotkeySetting: Codable, Sendable, Equatable {
    public var modifierKey: ModifierKey?
    public var keyCode: Int?
    public var modifiers: [HotkeyModifier]

    public init(modifierKey: ModifierKey? = nil, keyCode: Int? = nil, modifiers: [HotkeyModifier] = []) {
        self.modifierKey = modifierKey
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func modifier(_ key: ModifierKey) -> HotkeySetting { HotkeySetting(modifierKey: key) }
    public static func chord(_ keyCode: Int, _ modifiers: [HotkeyModifier]) -> HotkeySetting {
        HotkeySetting(keyCode: keyCode, modifiers: modifiers)
    }
}

public struct HotkeySettings: Codable, Sendable, Equatable {
    /// Hold to dictate; double tap = hands-free. Left Control is often taken by other dictation apps, so this is configurable (right Control, F18 = keyCode 79).
    public var dictation = HotkeySetting.modifier(.leftControl)
    /// Alternative hands-free chord (Ctrl+Space).
    public var handsFreeChord = HotkeySetting.chord(49, [.control])
    public var handsFreeChordEnabled = true
    public var pasteLast = HotkeySetting.chord(9, [.control, .command])   // V
    public var copyLast = HotkeySetting.chord(8, [.control, .command])    // C
    public var agent = HotkeySetting.modifier(.rightOption)
    public var notes = HotkeySetting.modifier(.rightCommand)
    public var callRecording = HotkeySetting.chord(15, [.control, .command]) // R
    /// Seconds a key must be held before it counts as hold-to-talk.
    public var holdThreshold = 0.3
    /// Seconds allowed between two taps for hands-free.
    public var doubleTapWindow = 0.4

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HotkeySettings()
        dictation = try c.decodeIfPresent(HotkeySetting.self, forKey: .dictation) ?? d.dictation
        handsFreeChord = try c.decodeIfPresent(HotkeySetting.self, forKey: .handsFreeChord) ?? d.handsFreeChord
        handsFreeChordEnabled = try c.decodeIfPresent(Bool.self, forKey: .handsFreeChordEnabled) ?? d.handsFreeChordEnabled
        pasteLast = try c.decodeIfPresent(HotkeySetting.self, forKey: .pasteLast) ?? d.pasteLast
        copyLast = try c.decodeIfPresent(HotkeySetting.self, forKey: .copyLast) ?? d.copyLast
        agent = try c.decodeIfPresent(HotkeySetting.self, forKey: .agent) ?? d.agent
        notes = try c.decodeIfPresent(HotkeySetting.self, forKey: .notes) ?? d.notes
        callRecording = try c.decodeIfPresent(HotkeySetting.self, forKey: .callRecording) ?? d.callRecording
        holdThreshold = try c.decodeIfPresent(Double.self, forKey: .holdThreshold) ?? d.holdThreshold
        doubleTapWindow = try c.decodeIfPresent(Double.self, forKey: .doubleTapWindow) ?? d.doubleTapWindow
    }
}

public enum DictationLanguage: String, Codable, Sendable, CaseIterable {
    case auto, ru, en
    public var languageMode: LanguageMode { self == .auto ? .auto : .fixed(rawValue) }
}

public enum InterfaceLanguage: String, Codable, Sendable, CaseIterable { case system, ru, en }
public enum AppTheme: String, Codable, Sendable, CaseIterable { case system, light, dark }

/// One row of the "Models" table (spec 4.3).
public struct ProviderChoice: Codable, Sendable, Equatable {
    public var providerID: ProviderID
    public var model: String
    public var baseURL: String?
    public init(providerID: ProviderID, model: String, baseURL: String? = nil) {
        self.providerID = providerID
        self.model = model
        self.baseURL = baseURL
    }
}

/// Provider per job. Jobs other than dictation have no default until their tasks pick a model.
public struct ProviderSettings: Codable, Sendable, Equatable {
    public var dictation: ProviderChoice? = ProviderChoice(providerID: .groq, model: "whisper-large-v3-turbo")
    public var dictationFallback: ProviderChoice?
    public var editor: ProviderChoice?
    public var callsByLanguage: ProviderChoice?
    public var callsMixedSpeech: ProviderChoice?
    public var callSummary: ProviderChoice?
    public var agent: ProviderChoice?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProviderSettings()
        dictation = c.contains(.dictation) ? try c.decodeIfPresent(ProviderChoice.self, forKey: .dictation) : d.dictation
        dictationFallback = try c.decodeIfPresent(ProviderChoice.self, forKey: .dictationFallback)
        editor = try c.decodeIfPresent(ProviderChoice.self, forKey: .editor)
        callsByLanguage = try c.decodeIfPresent(ProviderChoice.self, forKey: .callsByLanguage)
        callsMixedSpeech = try c.decodeIfPresent(ProviderChoice.self, forKey: .callsMixedSpeech)
        callSummary = try c.decodeIfPresent(ProviderChoice.self, forKey: .callSummary)
        agent = try c.decodeIfPresent(ProviderChoice.self, forKey: .agent)
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = Settings.currentSchemaVersion
    public var hotkeys = HotkeySettings()
    /// Microphone device UIDs, most preferred first. Empty = system default.
    public var micPriority: [String] = []
    public var dictationLanguage = DictationLanguage.auto
    public var interfaceLanguage = InterfaceLanguage.system
    public var theme = AppTheme.system
    public var audioRetentionDays = 90
    public var soundsEnabled = false   // off by default: the start sound was annoying in hands-on use (24.11)
    public var launchAtLogin = false
    public var providers = ProviderSettings()
    // T3.8
    /// Set once the first-run wizard has been finished or closed; it is never shown again.
    public var onboardingDone = false
    /// Fields written by a newer version (or by hand); written back untouched.
    public var unknownFields: [String: JSONValue] = [:]

    public init() {}

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum Known: String, CaseIterable {
        case schemaVersion, hotkeys, micPriority, dictationLanguage, interfaceLanguage, theme
        case audioRetentionDays, soundsEnabled, launchAtLogin, providers
        case preferences
        case onboardingDone // T3.8
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let d = Settings()
        func get<T: Decodable>(_ k: Known, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: AnyKey(k.rawValue)) ?? fallback
        }
        schemaVersion = try get(.schemaVersion, d.schemaVersion)
        hotkeys = try get(.hotkeys, d.hotkeys)
        micPriority = try get(.micPriority, d.micPriority)
        dictationLanguage = try get(.dictationLanguage, d.dictationLanguage)
        interfaceLanguage = try get(.interfaceLanguage, d.interfaceLanguage)
        theme = try get(.theme, d.theme)
        audioRetentionDays = try get(.audioRetentionDays, d.audioRetentionDays)
        soundsEnabled = try get(.soundsEnabled, d.soundsEnabled)
        launchAtLogin = try get(.launchAtLogin, d.launchAtLogin)
        providers = try get(.providers, d.providers)
        preferences = try get(.preferences, d.preferences)
        onboardingDone = try get(.onboardingDone, d.onboardingDone) // T3.8
        let known = Set(Known.allCases.map(\.rawValue))
        for key in c.allKeys where !known.contains(key.stringValue) {
            unknownFields[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in unknownFields { try c.encode(value, forKey: AnyKey(key)) }
        try c.encode(schemaVersion, forKey: AnyKey("schemaVersion"))
        try c.encode(hotkeys, forKey: AnyKey("hotkeys"))
        try c.encode(micPriority, forKey: AnyKey("micPriority"))
        try c.encode(dictationLanguage, forKey: AnyKey("dictationLanguage"))
        try c.encode(interfaceLanguage, forKey: AnyKey("interfaceLanguage"))
        try c.encode(theme, forKey: AnyKey("theme"))
        try c.encode(audioRetentionDays, forKey: AnyKey("audioRetentionDays"))
        try c.encode(soundsEnabled, forKey: AnyKey("soundsEnabled"))
        try c.encode(launchAtLogin, forKey: AnyKey("launchAtLogin"))
        try c.encode(providers, forKey: AnyKey("providers"))
        try c.encode(preferences, forKey: AnyKey("preferences"))
        try c.encode(onboardingDone, forKey: AnyKey("onboardingDone")) // T3.8
    }

    // T3.6: settings-screen fields live in one block so other tasks' additions do not collide with them.
    public var preferences = PreferenceSettings()
}

// MARK: - T3.6 settings-screen fields

public enum CallLanguage: String, Codable, Sendable, CaseIterable { case auto, ru, other }
public enum CallStartMode: String, Codable, Sendable, CaseIterable { case ask, auto }
/// How Susu works: through the Susu Cloud account, with the user's own keys, or fully on the Mac (spec 4.1).
public enum WorkMode: String, Codable, Sendable, CaseIterable { case cloud, ownKeys, macOnly }

/// Everything the settings screens added beyond the first Settings fields. Every field has a default.
public struct PreferenceSettings: Codable, Sendable, Equatable {
    // Microphone
    public var micSkipBuiltInWhenLidClosed = true
    public var micPreferMacOnHeadphones = true
    // Languages
    public var callLanguage = CallLanguage.auto
    /// ISO code used when `callLanguage` is `.other` ("pt", "es", ...).
    public var callOtherLanguage = "pt"
    public var mixedSpeech = true
    // Calls
    public var callStart = CallStartMode.ask
    /// Bundle IDs.
    public var callAlwaysApps: [String] = []
    public var callNeverApps: [String] = []
    public var callFinalPass = true
    public var callEchoCancellation = true
    // Agent
    public var agentTimeZone = "America/Sao_Paulo"
    /// Bundle IDs whose screen is never read (spec 7). Starts as the built-in list.
    public var contextExclusions: [String] = ContextRules.defaultExclusions.sorted()
    // Other
    public var dockIcon = false
    public var checkForUpdates = true
    // Account and models
    public var workMode = WorkMode.ownKeys
    /// Fallback provider per job id (`editor`, `callsByLanguage`, `callsMixedSpeech`, `callSummary`, `agent`).
    public var jobFallbacks: [String: ProviderChoice] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PreferenceSettings()
        micSkipBuiltInWhenLidClosed = try c.decodeIfPresent(Bool.self, forKey: .micSkipBuiltInWhenLidClosed) ?? d.micSkipBuiltInWhenLidClosed
        micPreferMacOnHeadphones = try c.decodeIfPresent(Bool.self, forKey: .micPreferMacOnHeadphones) ?? d.micPreferMacOnHeadphones
        callLanguage = try c.decodeIfPresent(CallLanguage.self, forKey: .callLanguage) ?? d.callLanguage
        callOtherLanguage = try c.decodeIfPresent(String.self, forKey: .callOtherLanguage) ?? d.callOtherLanguage
        mixedSpeech = try c.decodeIfPresent(Bool.self, forKey: .mixedSpeech) ?? d.mixedSpeech
        callStart = try c.decodeIfPresent(CallStartMode.self, forKey: .callStart) ?? d.callStart
        callAlwaysApps = try c.decodeIfPresent([String].self, forKey: .callAlwaysApps) ?? d.callAlwaysApps
        callNeverApps = try c.decodeIfPresent([String].self, forKey: .callNeverApps) ?? d.callNeverApps
        callFinalPass = try c.decodeIfPresent(Bool.self, forKey: .callFinalPass) ?? d.callFinalPass
        callEchoCancellation = try c.decodeIfPresent(Bool.self, forKey: .callEchoCancellation) ?? d.callEchoCancellation
        agentTimeZone = try c.decodeIfPresent(String.self, forKey: .agentTimeZone) ?? d.agentTimeZone
        contextExclusions = try c.decodeIfPresent([String].self, forKey: .contextExclusions) ?? d.contextExclusions
        dockIcon = try c.decodeIfPresent(Bool.self, forKey: .dockIcon) ?? d.dockIcon
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        workMode = try c.decodeIfPresent(WorkMode.self, forKey: .workMode) ?? d.workMode
        jobFallbacks = try c.decodeIfPresent([String: ProviderChoice].self, forKey: .jobFallbacks) ?? d.jobFallbacks
    }
}
