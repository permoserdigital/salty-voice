import SwiftUI
import Observation
import AppKit

enum PopoverPage: Equatable {
    case main
    case onboarding
    case settings
    case workflow
}

@Observable
@MainActor
final class AppState {
    private static let pasteRetryInitialAttempts = 22
    private static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    var activeWorkflow: (any Workflow)?
    var page: PopoverPage = .main
    var isPopoverShown = false
    var menuBarStatus: MenuBarStatus = .idle {
        didSet {
            guard oldValue != menuBarStatus else { return }
            onMenuBarStatusChange?(menuBarStatus)
            playTransitionSound(from: oldValue, to: menuBarStatus)
            updateRecordingLimit(for: menuBarStatus)
        }
    }
    var accessibilityPermissionGranted = false
    var localModelDownloadProgress: Double?
    var localModelDownloadStatusText: String?
    var localModelDownloadErrorText: String?
    var onMenuBarStatusChange: ((MenuBarStatus) -> Void)?
    private var activeLaunchSource: WorkflowLaunchSource = .manual
    /// Incremented on every workflow start/replacement; late callbacks from
    /// older workflows are ignored by comparing against this.
    private var workflowGeneration = 0
    private var activePasteTarget: PasteTarget?
    private var lastPopoverPasteTarget: PasteTarget?
    private var menuBarStatusResetTask: Task<Void, Never>?
    private var workflowCleanupTask: Task<Void, Never>?

    // Persisted settings
    var appSettings: AppSettings {
        didSet {
            saveSettings()
            prewarmLocalTranscriptionIfNeeded()
        }
    }
    var transcriptionSettings: TranscriptionSettings {
        didSet { saveSettings() }
    }
    var textImprovementSettings: TextImprovementSettings {
        didSet { saveSettings() }
    }
    var dampfAblassenSettings: DampfAblassenSettings {
        didSet { saveSettings() }
    }
    var emojiTextSettings: EmojiTextSettings {
        didSet { saveSettings() }
    }

    // Hotkeys
    let hotkeyService = HotkeyService()

    // Computed
    var isConfigured: Bool {
        KeychainService.isConfigured
            || isTeamConfigured
            || !LocalTranscriptionService.installedModels().isEmpty
    }

    /// Online features work with either a personal API key or a team server.
    var hasOnlineBackend: Bool {
        KeychainService.isConfigured || isTeamConfigured
    }
    var shouldShowOnboarding: Bool {
        !isConfigured && !appSettings.hasSeenOnboarding
    }

    var currentPhase: WorkflowPhase {
        activeWorkflow?.phase ?? .idle
    }

    init() {
        self.appSettings = Self.loadAppSettings()
        self.transcriptionSettings = Self.loadTranscriptionSettings()
        self.textImprovementSettings = Self.loadTextImprovementSettings()
        self.dampfAblassenSettings = Self.loadDampfAblassenSettings()
        self.emojiTextSettings = Self.loadEmojiTextSettings()
        refreshAccessibilityPermission()
        autoSelectFastLocalModelIfNeeded()
        prewarmLocalTranscriptionIfNeeded()
        refreshTeamWords()
        transcriptionHistory = TranscriptionHistoryService.load()
        SoundFeedbackService.isEnabled = { [weak self] in
            self?.appSettings.soundFeedbackEnabled ?? true
        }
        startUpdateChecks()
    }

    // MARK: - Update Check

    var availableUpdateVersion: String?
    private var dismissedUpdateVersion: String?
    private var updateCheckTimer: Timer?

    func dismissUpdateHint() {
        dismissedUpdateVersion = availableUpdateVersion
        availableUpdateVersion = nil
    }

    private func startUpdateChecks() {
        checkForUpdate()
        // Menu bar apps run for weeks; re-check twice a day.
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpdate()
            }
        }
    }

    private func checkForUpdate() {
        Task { @MainActor [weak self] in
            guard let version = await UpdateCheckService.checkForUpdate() else { return }
            guard version != self?.dismissedUpdateVersion else { return }
            self?.availableUpdateVersion = version
        }
    }

    // MARK: - Transcription History

    var transcriptionHistory: [TranscriptionHistoryEntry] = []

    func clearTranscriptionHistory() {
        TranscriptionHistoryService.clear()
        transcriptionHistory = []
    }

    // MARK: - Sounds & Recording Limit

    static let maxRecordingDuration: TimeInterval = 300  // 5 minutes
    private static let countdownWindow: TimeInterval = 60

    var onRecordingCountdownChange: ((Int?) -> Void)?
    private var recordingLimitTask: Task<Void, Never>?

    private func playTransitionSound(from oldStatus: MenuBarStatus, to newStatus: MenuBarStatus) {
        switch newStatus {
        case .recording:
            SoundFeedbackService.play(.recordingStarted)
        case .processing:
            if case .recording = oldStatus {
                SoundFeedbackService.play(.recordingStopped)
            }
        case .success:
            SoundFeedbackService.play(.success)
        case .error:
            SoundFeedbackService.play(.error)
        case .idle:
            break
        }
    }

    private func updateRecordingLimit(for status: MenuBarStatus) {
        if case .recording = status {
            startRecordingLimitCountdown()
        } else {
            stopRecordingLimitCountdown()
        }
    }

    private func startRecordingLimitCountdown() {
        recordingLimitTask?.cancel()
        let startedAt = Date()
        var hasWarned = false

        recordingLimitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }

                let remaining = Self.maxRecordingDuration - Date().timeIntervalSince(startedAt)

                if remaining <= Self.countdownWindow {
                    if !hasWarned {
                        hasWarned = true
                        SoundFeedbackService.play(.limitWarning)
                    }
                    self.onRecordingCountdownChange?(max(0, Int(remaining.rounded())))
                }

                if remaining <= 0 {
                    // Hard limit reached: stop and transcribe what we have.
                    self.activeWorkflow?.stop()
                    return
                }
            }
        }
    }

    private func stopRecordingLimitCountdown() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        onRecordingCountdownChange?(nil)
    }

    // MARK: - Team Vocabulary

    var teamSyncStatusText: String?

    var isTeamConfigured: Bool {
        !appSettings.teamServerURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !appSettings.teamCode.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var teamWords: [String] { appSettings.cachedTeamWords }

    /// Personal terms plus synced team terms, deduplicated (case-insensitive).
    var combinedCustomTerms: [String] {
        var seen = Set<String>()
        return (textImprovementSettings.customTerms + appSettings.cachedTeamWords)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    func refreshTeamWords() {
        guard isTeamConfigured else { return }
        let serverURL = appSettings.teamServerURL
        let code = appSettings.teamCode
        teamSyncStatusText = "Synchronisiere ..."

        Task { @MainActor [weak self] in
            do {
                let words = try await TeamVocabularyService.fetchWords(serverURL: serverURL, teamCode: code)
                guard let self else { return }
                self.appSettings.cachedTeamWords = words
                self.teamSyncStatusText = "\(words.count) Team-Wörter synchronisiert."
            } catch {
                self?.teamSyncStatusText = error.localizedDescription
            }
        }
    }

    var feedbackStatusText: String?

    func sendFeedback(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isTeamConfigured else { return }
        let serverURL = appSettings.teamServerURL
        let code = appSettings.teamCode
        feedbackStatusText = "Sende Feedback ..."

        Task { @MainActor [weak self] in
            do {
                try await TeamVocabularyService.sendFeedback(
                    serverURL: serverURL,
                    teamCode: code,
                    message: trimmed,
                    appVersion: UpdateCheckService.currentVersion,
                    sender: NSFullUserName()
                )
                self?.feedbackStatusText = "Danke! Feedback wurde gesendet. 🙏"
            } catch {
                self?.feedbackStatusText = "Senden fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    func addTeamWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, isTeamConfigured else { return }
        let serverURL = appSettings.teamServerURL
        let code = appSettings.teamCode
        teamSyncStatusText = "Sende \"\(trimmed)\" ..."

        Task { @MainActor [weak self] in
            do {
                let words = try await TeamVocabularyService.addWord(serverURL: serverURL, teamCode: code, word: trimmed)
                guard let self else { return }
                self.appSettings.cachedTeamWords = words
                self.teamSyncStatusText = "\"\(trimmed)\" für das Team gespeichert."
            } catch {
                self?.teamSyncStatusText = error.localizedDescription
            }
        }
    }

    // MARK: - Custom Display Names

    func displayName(for type: WorkflowType) -> String {
        switch type {
        case .textImprover:
            let name = textImprovementSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .dampfAblassen:
            let name = dampfAblassenSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .emojiText:
            let name = emojiTextSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        default:
            return type.displayName
        }
    }

    func workflowSubtitle(for type: WorkflowType) -> String {
        switch type {
        case .transcription:
            if appSettings.secureLocalModeEnabled {
                let modelName = selectedLocalModelName
                return LocalTranscriptionService.isModelInstalled(modelName)
                    ? "Lokal: \(LocalTranscriptionModel.displayName(for: modelName))."
                    : "Lokales WhisperKit-Modell fehlt."
            }
            return "Online: Whisper über OpenAI."
        case .localTranscription:
            return "Nur lokal. Kein Server."
        case .textImprover, .dampfAblassen, .emojiText:
            if appSettings.secureLocalModeEnabled {
                return "Im lokalen Modus pausiert."
            }
            return type.subtitle
        }
    }

    var resolvedLocalModelName: String {
        LocalTranscriptionService.resolvedModelName(appSettings.selectedLocalTranscriptionModelName)
    }

    var selectedLocalModelDisplayName: String {
        LocalTranscriptionModel.displayName(for: selectedLocalModelName)
    }

    var selectedLocalModelName: String {
        LocalTranscriptionService.normalizedModelName(appSettings.selectedLocalTranscriptionModelName)
    }

    var selectedLocalModelIsInstalled: Bool {
        LocalTranscriptionService.isModelInstalled(selectedLocalModelName)
    }

    var isDownloadingLocalModel: Bool {
        localModelDownloadProgress != nil
    }

    var localModelDownloadButtonTitle: String {
        selectedLocalModelIsInstalled
            ? "\(LocalTranscriptionModel.displayName(for: selectedLocalModelName)) ist installiert"
            : "\(LocalTranscriptionModel.displayName(for: selectedLocalModelName)) installieren"
    }

    // MARK: - Workflow Management

    func startWorkflow(_ type: WorkflowType, source: WorkflowLaunchSource = .manual) {
        guard isWorkflowAvailable(type) else {
            if source == .manual {
                page = .settings
            } else {
                // Hotkey arrived but the workflow is not configured (e.g. no
                // API key). Flash the menu bar icon instead of failing silently.
                menuBarStatus = .error(type)
                scheduleMenuBarStatusReset(after: 1.6)
            }
            return
        }

        // Discard (never transcribe) any workflow we are replacing, and bump
        // the generation so its late callbacks are ignored.
        workflowGeneration += 1
        activeWorkflow?.reset()
        menuBarStatusResetTask?.cancel()
        workflowCleanupTask?.cancel()
        activeLaunchSource = source
        activePasteTarget = capturePasteTarget(for: source)

        switch type {
        case .transcription:
            let workflow = TranscriptionWorkflow(
                customTerms: combinedCustomTerms,
                language: transcriptionSettings.language,
                backend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .localTranscription:
            let workflow = TranscriptionWorkflow(
                type: .localTranscription,
                customTerms: combinedCustomTerms,
                language: transcriptionSettings.language,
                backend: .local,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .textImprover:
            // Inject team words so the improver also knows them.
            var settingsWithTeamTerms = textImprovementSettings
            settingsWithTeamTerms.customTerms = combinedCustomTerms
            let workflow = TextImprovementWorkflow(
                settings: settingsWithTeamTerms,
                language: transcriptionSettings.language
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .dampfAblassen:
            let workflow = DampfAblassenWorkflow(
                settings: dampfAblassenSettings,
                customTerms: combinedCustomTerms,
                language: transcriptionSettings.language
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .emojiText:
            let workflow = EmojiTextWorkflow(
                settings: emojiTextSettings,
                customTerms: combinedCustomTerms,
                language: transcriptionSettings.language
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()
        }

        page = source.presentsWorkflowPage ? .workflow : .main
    }

    func isWorkflowAvailable(_ type: WorkflowType) -> Bool {
        switch type {
        case .localTranscription:
            return selectedLocalModelIsInstalled
        case .transcription:
            return appSettings.secureLocalModeEnabled
                ? selectedLocalModelIsInstalled
                : hasOnlineBackend
        case .textImprover, .dampfAblassen, .emojiText:
            return !appSettings.secureLocalModeEnabled && hasOnlineBackend
        }
    }

    func stopCurrentWorkflow() {
        activeWorkflow?.stop()
    }

    /// Escape: abort and DISCARD the current recording/processing --
    /// nothing gets transcribed or pasted.
    func abortCurrentWorkflow() {
        guard activeWorkflow != nil else { return }
        workflowGeneration += 1
        activeWorkflow?.reset()
        activeWorkflow = nil
        activePasteTarget = nil
        activeLaunchSource = .manual
        workflowCleanupTask?.cancel()
        menuBarStatusResetTask?.cancel()
        menuBarStatus = .idle
        if !isPopoverShown { page = .main }
        SoundFeedbackService.play(.cancelled)
    }

    func resetCurrentWorkflow() {
        workflowGeneration += 1
        activeWorkflow?.reset()
        activeWorkflow = nil
        activePasteTarget = nil
        activeLaunchSource = .manual
        menuBarStatusResetTask?.cancel()
        workflowCleanupTask?.cancel()
        menuBarStatus = .idle
        page = .main
    }

    func enableSecureLocalMode() {
        appSettings.secureLocalModeEnabled = true
        if !selectedLocalModelIsInstalled {
            installSelectedLocalModel()
        }
    }

    func installSelectedLocalModel() {
        guard !isDownloadingLocalModel else { return }

        let modelName = selectedLocalModelName
        localModelDownloadProgress = 0
        localModelDownloadStatusText = "Download startet..."
        localModelDownloadErrorText = nil

        Task {
            do {
                let installedURL = try await LocalTranscriptionService.shared.downloadAndInstall(
                    modelName: modelName
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let clampedProgress = min(max(progress, 0), 1)
                        self.localModelDownloadProgress = clampedProgress
                        self.localModelDownloadStatusText = "Download \(Int(clampedProgress * 100)) %"
                    }
                }

                appSettings.selectedLocalTranscriptionModelName = installedURL.lastPathComponent
                appSettings.secureLocalModeEnabled = true
                localModelDownloadProgress = nil
                localModelDownloadStatusText = "\(LocalTranscriptionModel.displayName(for: modelName)) ist installiert."
                localModelDownloadErrorText = nil

                try? await LocalTranscriptionService.shared.prepare(modelName: modelName)
            } catch {
                localModelDownloadProgress = nil
                localModelDownloadStatusText = nil
                localModelDownloadErrorText = error.localizedDescription
            }
        }
    }

    func copyToClipboard(_ text: String) {
        writeSensitiveTextToPasteboard(text)
    }

    // MARK: - Auto-Paste

    /// Copies the text, restores focus when needed, then simulates Cmd+V.
    /// The text intentionally remains on the clipboard as a fallback if paste is blocked.
    private func pasteAtCursor(_ text: String, target: PasteTarget? = nil) {
        writeSensitiveTextToPasteboard(text)

        if isPopoverShown {
            NotificationCenter.default.post(name: .dismissPopover, object: nil)
        }

        let trusted = AccessibilityPermissionService.isTrusted(promptIfNeeded: true)
        accessibilityPermissionGranted = trusted
        guard trusted else {
            menuBarStatus = .error(activeWorkflow?.type)
            return
        }

        attemptPasteTrusted(
            target: target,
            attemptsRemaining: Self.pasteRetryInitialAttempts
        )
    }

    private func writeSensitiveTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.concealedPasteboardType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedPasteboardType)
    }

    func prepareForPopoverPresentation() {
        lastPopoverPasteTarget = captureCurrentFrontmostApp()
        if let activeWorkflow, activeWorkflow.phase.isActive {
            page = .workflow
        } else if shouldShowOnboarding {
            page = .onboarding
            markOnboardingSeen()
        } else if page == .workflow {
            page = .main
        } else if page == .onboarding {
            page = .main
        }
    }

    func markOnboardingSeen() {
        guard !appSettings.hasSeenOnboarding else { return }
        appSettings.hasSeenOnboarding = true
    }

    // MARK: - API Key Status

    func apiKeyDisplayValue(for key: KeychainKey) -> String {
        guard let value = KeychainService.load(key: key), !value.isEmpty else {
            return ""
        }
        if value.count > 8 {
            return String(value.prefix(4)) + " \u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
        }
        return "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
    }

    func hasValue(for key: KeychainKey) -> Bool {
        guard let value = KeychainService.load(key: key) else { return false }
        return !value.isEmpty
    }

    // MARK: - Settings Persistence

    private static let settingsURL: URL = {
        try? AppSupportPaths.ensureAppSupportDirectoryExists()
        return AppSupportPaths.settingsURL
    }()

    private var settingsSaveTask: Task<Void, Never>?

    /// Debounced: bound TextFields mutate settings on every keystroke;
    /// writing once after a short pause avoids per-key disk writes.
    private func saveSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.writeSettingsNow()
        }
    }

    private func writeSettingsNow() {
        let container = SettingsContainer(
            app: appSettings,
            transcription: transcriptionSettings,
            textImprovement: textImprovementSettings,
            dampfAblassen: dampfAblassenSettings,
            emojiText: emojiTextSettings
        )
        if let data = try? JSONEncoder().encode(container) {
            // Atomic: TeamVocabularyService reads this file concurrently.
            try? data.write(to: Self.settingsURL, options: [.atomic])
        }
    }

    private static func loadAppSettings() -> AppSettings {
        loadContainer()?.app ?? AppSettings()
    }

    private static func loadTranscriptionSettings() -> TranscriptionSettings {
        loadContainer()?.transcription ?? TranscriptionSettings()
    }

    private static func loadTextImprovementSettings() -> TextImprovementSettings {
        loadContainer()?.textImprovement ?? TextImprovementSettings()
    }

    private static func loadDampfAblassenSettings() -> DampfAblassenSettings {
        loadContainer()?.dampfAblassen ?? DampfAblassenSettings()
    }

    private static func loadEmojiTextSettings() -> EmojiTextSettings {
        loadContainer()?.emojiText ?? EmojiTextSettings()
    }

    private static func loadContainer() -> SettingsContainer? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(SettingsContainer.self, from: data)
    }

    func refreshAccessibilityPermission() {
        accessibilityPermissionGranted = AccessibilityPermissionService.currentStatus()
    }

    func requestAccessibilityPermission() {
        accessibilityPermissionGranted = AccessibilityPermissionService.requestPermissionPrompt()
        AccessibilityPermissionService.openSystemSettings()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshAccessibilityPermission()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refreshAccessibilityPermission()
        }
    }

    private func autoSelectFastLocalModelIfNeeded() {
        guard !appSettings.hasAutoSelectedFastLocalModel,
              LocalTranscriptionService.shouldAutoSelectRecommendedFastModel(
                currentModelName: appSettings.selectedLocalTranscriptionModelName
              ) else {
            return
        }

        appSettings.selectedLocalTranscriptionModelName = LocalTranscriptionService.recommendedFastModelName
        appSettings.hasAutoSelectedFastLocalModel = true
    }

    private var prewarmedLocalModelName: String?

    private func prewarmLocalTranscriptionIfNeeded() {
        guard appSettings.secureLocalModeEnabled,
              LocalTranscriptionService.isModelInstalled(resolvedLocalModelName) else {
            return
        }

        let modelName = resolvedLocalModelName
        // Settings mutate on every keystroke; only prewarm once per model.
        guard modelName != prewarmedLocalModelName else { return }
        prewarmedLocalModelName = modelName
        Task.detached(priority: .utility) {
            try? await LocalTranscriptionService.shared.prepare(modelName: modelName)
        }
    }

    private func handleWorkflowOutput(_ text: String, workflowType: WorkflowType) {
        transcriptionHistory = TranscriptionHistoryService.append(text: text, workflowType: workflowType)
        pasteAtCursor(text, target: activePasteTarget)
        if activeLaunchSource == .hotkeyBackground {
            page = .main
        }
        scheduleWorkflowCleanup(after: 1.05)
    }

    private func configureWorkflowHandlers<T: Workflow>(_ workflow: T) {
        let generation = workflowGeneration
        workflow.onOutput = { [weak self, weak workflow] text in
            guard let self, let workflow,
                  generation == self.workflowGeneration,
                  workflow === self.activeWorkflow else { return }
            self.handleWorkflowOutput(text, workflowType: workflow.type)
        }
        workflow.onPhaseChange = { [weak self, weak workflow] phase in
            guard let self, let workflow,
                  generation == self.workflowGeneration,
                  workflow === self.activeWorkflow else { return }
            self.handleWorkflowPhaseChange(phase, workflow: workflow)
        }
    }

    private func handleWorkflowPhaseChange(_ phase: WorkflowPhase, workflow: any Workflow) {
        menuBarStatusResetTask?.cancel()

        switch phase {
        case .idle:
            if activeWorkflow == nil {
                menuBarStatus = .idle
            }

        case .running:
            menuBarStatus = workflow.isRecording
                ? .recording(workflow.type)
                : .processing(workflow.type)

        case .done:
            menuBarStatus = .success(workflow.type)

        case .error:
            menuBarStatus = .error(workflow.type)
            if activeLaunchSource == .hotkeyBackground {
                activeWorkflow = nil
                activePasteTarget = nil
                page = .main
            }
            scheduleMenuBarStatusReset(after: 1.6)
        }
    }

    private func scheduleWorkflowCleanup(after delay: TimeInterval) {
        guard let workflow = activeWorkflow else { return }

        workflowCleanupTask?.cancel()
        let workflowID = ObjectIdentifier(workflow)

        workflowCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let activeWorkflow = self.activeWorkflow else { return }
            guard ObjectIdentifier(activeWorkflow) == workflowID else { return }

            activeWorkflow.reset()
            self.activeWorkflow = nil
            self.activePasteTarget = nil
            self.activeLaunchSource = .manual
            if !self.isPopoverShown {
                self.page = .main
            }
            self.menuBarStatus = .idle
        }
    }

    private func scheduleMenuBarStatusReset(after delay: TimeInterval) {
        menuBarStatusResetTask?.cancel()
        menuBarStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            if self.activeWorkflow == nil || !(self.activeWorkflow?.phase.isActive ?? false) {
                self.menuBarStatus = .idle
            }
        }
    }

    private func capturePasteTarget(for source: WorkflowLaunchSource) -> PasteTarget? {
        switch source {
        case .manual:
            return lastPopoverPasteTarget
        case .hotkeyBackground:
            return captureCurrentFrontmostApp()
        }
    }

    private func attemptPasteTrusted(
        target: PasteTarget?,
        attemptsRemaining: Int
    ) {
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if let target {
            if frontmostPid == target.processIdentifier {
                performPaste()
                return
            }

            target.application.activate(options: [])
        } else {
            notifyPasteFallback()
            return
        }

        guard attemptsRemaining > 0 else {
            notifyPasteFallback()
            return
        }

        let delay: TimeInterval
        switch attemptsRemaining {
        case 16...:
            delay = 0.015
        case 8...15:
            delay = 0.025
        default:
            delay = 0.04
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptPasteTrusted(
                target: target,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    /// Paste could not be delivered (target app gone or never captured).
    /// The text stays on the clipboard; flash the icon so the user notices.
    private func notifyPasteFallback() {
        menuBarStatus = .error(activeWorkflow?.type)
        scheduleMenuBarStatusReset(after: 1.6)
    }

    private func performPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func captureCurrentFrontmostApp() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let ownPid = NSRunningApplication.current.processIdentifier
        guard app.processIdentifier != ownPid else { return nil }

        return PasteTarget(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            application: app
        )
    }
}

private struct SettingsContainer: Codable {
    var app: AppSettings?
    var transcription: TranscriptionSettings
    var textImprovement: TextImprovementSettings
    var dampfAblassen: DampfAblassenSettings?
    var emojiText: EmojiTextSettings?
}

// MARK: - Notification for Popover Dismissal

extension Notification.Name {
    static let dismissPopover = Notification.Name("dismissPopover")
}

private struct PasteTarget {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let application: NSRunningApplication
}
