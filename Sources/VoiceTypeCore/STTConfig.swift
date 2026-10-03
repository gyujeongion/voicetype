import Foundation

/// Real-time WebSocket STT engines natively supported by VoiceType.
public enum STTProvider: String, Codable, Sendable, CaseIterable {
    case deepgram
    case soniox
    case custom   // custom WebSocket endpoint (protocol compatibility varies)
}

public struct STTConfig: Codable, Sendable {
    public var provider: STTProvider
    /// WebSocket endpoint for custom provider
    public var customEndpoint: String

    public init(provider: STTProvider = .deepgram, customEndpoint: String = "") {
        self.provider = provider
        self.customEndpoint = customEndpoint
    }
}

public struct STTPreset: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let provider: STTProvider
    public let noteKey: String
    public let isRecommended: Bool
    /// Custom endpoint URL to auto-fill when this preset is selected
    public let customEndpoint: String?

    public init(name: String, provider: STTProvider, noteKey: String,
                isRecommended: Bool = false, customEndpoint: String? = nil) {
        self.name = name
        self.provider = provider
        self.noteKey = noteKey
        self.isRecommended = isRecommended
        self.customEndpoint = customEndpoint
    }
}

/// All known presets. Deepgram and Soniox are natively supported (full protocol integration).
/// "Custom" speaks the Soniox WebSocket protocol only — other vendors (Gladia, AssemblyAI,
/// Speechmatics, Rev.ai, Symbl) use different protocols and silently failed when listed here,
/// so they were removed (2026-10-03).
public enum STTPresets {
    public static let all: [STTPreset] = [
        // ── Natively supported ────────────────────────────────────────────────
        STTPreset(name: "Deepgram Nova-3",
                  provider: .deepgram,
                  noteKey: "stt.preset.deepgram.note",
                  isRecommended: true),
        STTPreset(name: "Soniox",
                  provider: .soniox,
                  noteKey: "stt.preset.soniox.note",
                  isRecommended: true),

        // ── Fully custom ──────────────────────────────────────────────────────
        STTPreset(name: "Custom",
                  provider: .custom,
                  noteKey: "stt.preset.custom.note",
                  customEndpoint: nil),
    ]

    public static func name(for provider: STTProvider) -> String {
        all.first(where: { $0.provider == provider && $0.isRecommended })?.name
            ?? all.first(where: { $0.provider == provider })?.name
            ?? provider.rawValue
    }
}
