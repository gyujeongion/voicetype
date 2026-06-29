import Foundation

/// 핫키 동작 방식: 토글(한 번 누름 → 시작/종료) vs 푸시투토크(누르는 동안만 녹음)
public enum TriggerMode: String, Codable, CaseIterable, Sendable {
    case toggle
    case pushToTalk
}

/// Dictation profile — each profile has its own hotkey and processing mode.
public struct PromptProfile: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var hotkeyKeyCode: UInt32
    public var hotkeyModifiers: UInt32
    /// true면 LLM 후처리(instruction 적용), false면 STT + 단어사전 보정만
    public var useLLM: Bool
    /// LLM 지시문 (번역/요약/정리 등). useLLM=false면 무시.
    public var instruction: String
    /// 토글 방식 vs 꾹눌러서 녹음 방식
    public var triggerMode: TriggerMode

    public init(id: UUID = UUID(),
                name: String,
                hotkeyKeyCode: UInt32,
                hotkeyModifiers: UInt32 = 0,
                useLLM: Bool = false,
                instruction: String = "",
                triggerMode: TriggerMode = .toggle) {
        self.id = id
        self.name = name
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.useLLM = useLLM
        self.instruction = instruction
        self.triggerMode = triggerMode
    }

    // 관대한 디코딩 — 향후 필드 추가/변경에도 기존 프로파일 보존
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "프롬프트"
        hotkeyKeyCode = (try? c.decode(UInt32.self, forKey: .hotkeyKeyCode)) ?? 0
        hotkeyModifiers = (try? c.decode(UInt32.self, forKey: .hotkeyModifiers)) ?? 0
        useLLM = (try? c.decode(Bool.self, forKey: .useLLM)) ?? false
        instruction = (try? c.decode(String.self, forKey: .instruction)) ?? ""
        triggerMode = (try? c.decode(TriggerMode.self, forKey: .triggerMode)) ?? .toggle
    }
}

/// 앱 설정 모델 (Codable). 영속화는 앱 레이어(UserDefaults/Keychain)에서.
public struct AppSettings: Codable, Sendable {
    /// 받아쓰기 프로파일들 (각자 단축키)
    public var profiles: [PromptProfile]

    /// 마이크 우선순위 (uid 문자열 목록). 위에서부터 우선, 연결된 첫 장치 사용.
    public var microphonePriority: [String]

    /// 명시적으로 사용할 마이크 UID. nil이면 우선순위/시스템 기본값을 사용.
    public var selectedMicrophoneUID: String?

    /// STT 언어 힌트
    public var languageHints: [String]

    public var dictionary: TermDictionary
    public var llm: LLMConfig
    public var stt: STTConfig

    /// 붙여넣기 동작
    public var autoPaste: Bool
    public var copyToClipboard: Bool

    /// In-app language override. 빈 문자열이면 지역 기반 기본값 사용.
    public var appLanguage: String

    /// Space 꾹누르기 → 음성 입력 모드 활성화
    public var spaceBarTrigger: Bool
    /// Space key-repeat 임계값 (이 횟수 이상이면 기동)
    public var spaceBarThreshold: Int
    /// Space 꾹누르기에 사용할 프로파일 id. nil이면 첫 번째 프로파일 사용.
    public var spaceBarProfileID: UUID?
    /// Space 꾹누르기를 비활성화할 앱 bundle id 목록
    public var spaceBarExcludedAppBundleIDs: [String]

    public init(profiles: [PromptProfile]? = nil,
                microphonePriority: [String] = [],
                selectedMicrophoneUID: String? = nil,
                languageHints: [String] = ["ko", "en"],
                dictionary: TermDictionary = TermDictionary(),
                llm: LLMConfig = LLMConfig(),
                stt: STTConfig = STTConfig(),
                autoPaste: Bool = true,
                copyToClipboard: Bool = true,
                appLanguage: String = "",
                spaceBarTrigger: Bool = false,
                spaceBarThreshold: Int = 3,
                spaceBarProfileID: UUID? = nil,
                spaceBarExcludedAppBundleIDs: [String] = []) {
        self.profiles = profiles ?? AppSettings.defaultProfiles
        self.microphonePriority = microphonePriority
        self.selectedMicrophoneUID = selectedMicrophoneUID
        self.languageHints = languageHints
        self.dictionary = dictionary
        self.llm = llm
        self.stt = stt
        self.autoPaste = autoPaste
        self.copyToClipboard = copyToClipboard
        self.appLanguage = appLanguage
        self.spaceBarTrigger = spaceBarTrigger
        self.spaceBarThreshold = spaceBarThreshold
        self.spaceBarProfileID = spaceBarProfileID
        self.spaceBarExcludedAppBundleIDs = spaceBarExcludedAppBundleIDs
    }

    enum CodingKeys: String, CodingKey {
        case profiles, microphonePriority, selectedMicrophoneUID, languageHints, dictionary, llm, stt
        case autoPaste, copyToClipboard, appLanguage
        case spaceBarTrigger, spaceBarThreshold, spaceBarProfileID, spaceBarExcludedAppBundleIDs
    }

    // 관대한 디코딩 — 향후 필드 추가/변경에도 기존 설정(특히 프로파일)을 최대한 보존
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = (try? c.decode([PromptProfile].self, forKey: .profiles)) ?? AppSettings.defaultProfiles
        microphonePriority = (try? c.decode([String].self, forKey: .microphonePriority)) ?? []
        selectedMicrophoneUID = try? c.decodeIfPresent(String.self, forKey: .selectedMicrophoneUID)
        languageHints = (try? c.decode([String].self, forKey: .languageHints)) ?? ["ko", "en"]
        dictionary = (try? c.decode(TermDictionary.self, forKey: .dictionary)) ?? TermDictionary()
        llm = (try? c.decode(LLMConfig.self, forKey: .llm)) ?? LLMConfig()
        stt = (try? c.decode(STTConfig.self, forKey: .stt)) ?? STTConfig()
        autoPaste = (try? c.decode(Bool.self, forKey: .autoPaste)) ?? true
        copyToClipboard = (try? c.decode(Bool.self, forKey: .copyToClipboard)) ?? true
        appLanguage = (try? c.decode(String.self, forKey: .appLanguage)) ?? ""
        spaceBarTrigger = (try? c.decode(Bool.self, forKey: .spaceBarTrigger)) ?? false
        spaceBarThreshold = (try? c.decode(Int.self, forKey: .spaceBarThreshold)) ?? 3
        spaceBarProfileID = try? c.decodeIfPresent(UUID.self, forKey: .spaceBarProfileID)
        spaceBarExcludedAppBundleIDs = (try? c.decode([String].self, forKey: .spaceBarExcludedAppBundleIDs)) ?? []
    }

    /// Default profiles: Option+Space for dictation, Option+Shift+Space for English translation.
    /// kVK_Space = 49, optionKey = 2048, shiftKey = 512
    public static let defaultProfiles: [PromptProfile] = [
        PromptProfile(name: "Dictation", hotkeyKeyCode: 49, hotkeyModifiers: 2048,  // Option+Space
                      useLLM: true,
                      instruction: """
                      입력은 내가 말한 걸 STT로 받아쓴 거친 전사문이야. 의미와 핵심 정보는 절대 바꾸거나 빠뜨리지 말고, 아래만 다듬어 깔끔한 문장으로 만들어줘:
                      - '음/어/그/저/그러니까' 같은 군더더기·머뭇거림 제거
                      - 더듬어 반복한 말은 한 번으로 정리
                      - 말하다 고쳐 말한 경우(자기수정) 최종 의도한 표현만 남김
                      - 띄어쓰기·맞춤법·문장부호 교정
                      새 내용 추가·요약·의역은 금지. 말투(반말/존댓말)는 원래대로 유지.
                      """),
        PromptProfile(name: "Translate to English", hotkeyKeyCode: 49, hotkeyModifiers: 2560,  // Option+Shift+Space
                      useLLM: true,
                      instruction: "내가 말한 한국어를 자연스럽고 유창한 영어로 번역해줘. 직역하지 말고 원어민이 실제로 쓰는 표현으로. 번역문만 출력."),
    ]

    public static let `default` = AppSettings()

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decoded(from data: Data) -> AppSettings? {
        try? JSONDecoder().decode(AppSettings.self, from: data)
    }
}
