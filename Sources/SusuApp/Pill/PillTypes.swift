// Public types of the pill: states, menu closures, exact sizes (docs/design/prototype/components.css, section "pill").
import Foundation
import SusuCore

/// What the pill shows. `hover` is normally set by the pill itself when the mouse is over it.
public enum PillState: Equatable, Sendable {
    case idle
    case hover
    /// Ctrl held > 0.3 s. `confirmed` is false until the microphone reports it is recording (bars at 40%).
    case listening(confirmed: Bool)
    case handsFree
    case processing
    case agentListening
    /// Agent thinking: accent dots (PILL.agent-working).
    case agentWorking
    /// Agent card is open (PILL.agent-waiting-confirm).
    case agentWaiting
    case noteListening
    /// Brick hairline; a toast usually sits above.
    case error
}

/// One row of the microphone / language submenu.
public struct PillMenuChoice: Sendable {
    public var id: String
    public var title: String
    public var isSelected: Bool
    public init(id: String, title: String, isSelected: Bool) {
        self.id = id; self.title = title; self.isSelected = isSelected
    }
}

/// Right-click menu content (spec 1.5). The pill owns the menu, the app supplies the data and the reactions.
public struct PillMenuHandlers {
    public var pasteLast: @MainActor () -> Void = {}
    public var openHistory: @MainActor () -> Void = {}
    public var microphones: @MainActor () -> [PillMenuChoice] = { [] }
    public var selectMicrophone: @MainActor (String) -> Void = { _ in }
    public var languages: @MainActor () -> [PillMenuChoice] = { [] }
    public var selectLanguage: @MainActor (String) -> Void = { _ in }
    public var hideForHour: @MainActor () -> Void = {}
    public var openSettings: @MainActor () -> Void = {}
    public init() {}
}

/// Sizes in points, straight from the approved prototype (components.css / desktop.html).
/// Note: docs/ux-map.md still lists older numbers (44x24, 76x28, 132x28); the prototype won at Gate D.
enum PillMetrics {
    static func size(for state: PillState, callDot: Bool) -> CGSize {
        switch state {
        case .idle: callDot ? CGSize(width: 56, height: 16) : CGSize(width: 36, height: 6)
        case .hover, .agentWaiting, .error: CGSize(width: 52, height: 28)
        // ponytail: smaller than the prototype (96x36): found too big next to Wispr's pill in hands-on use (24.11).
        case .listening, .processing, .agentListening, .agentWorking: CGSize(width: 72, height: 26)
        case .noteListening: CGSize(width: 92, height: 26)
        case .handsFree: CGSize(width: 158, height: 44)
        }
    }

    /// Transparent panel around the capsule: room for the hint bubble above and the drop shadow around.
    static let panelSize = CGSize(width: 300, height: 124)
    /// Distance from the panel bottom to the capsule bottom (shadow room).
    static let bottomInset: CGFloat = 32
    /// Gap between the Dock / visible area and the capsule.
    static let dockGap: CGFloat = 64   // sits above Wispr Flow's pill at the bottom centre
    /// Centre of the capsule when snapped to the left / right edge.
    static let edgeInset: CGFloat = 64
    static let hintGap: CGFloat = 10
    static let hintHeight: CGFloat = 30
    static let positionKey = "susu.pill.centerFraction"
}

extension PillState {
    var isListeningLike: Bool {
        switch self {
        case .listening, .handsFree, .agentListening, .noteListening: true
        default: false
        }
    }
    var isAgent: Bool {
        switch self {
        case .agentListening, .agentWorking, .agentWaiting: true
        default: false
        }
    }
}

enum PillL10n {
    static func string(_ key: String, _ language: InterfaceLanguage) -> String {
        L10n.bundle(for: language).localizedString(forKey: key, value: key, table: "Pill")
    }
    static func format(_ key: String, _ language: InterfaceLanguage, _ args: CVarArg...) -> String {
        String(format: string(key, language), arguments: args)
    }
}
