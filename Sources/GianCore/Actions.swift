import Foundation

public enum GianClientAction: Sendable {
    /// Sets the Remote Server and verifies its identity (pinned on first
    /// use); Host pairing comes next. There is no account sign-in.
    case setServerAddress(String)
    /// After the Server's identity changed (e.g. it was reinstalled): forget
    /// the pinned identity and this app's Hosts there, then connect again.
    case forgetServerIdentity
    case logout
    /// Pairs a Host: during setup, or later to add another Host (the current
    /// one stays open until the new one is confirmed, then becomes current).
    case beginHostPairingFromQR(String)
    case refreshHostPairing
    /// Abandons the pairing in progress (Add Host's Cancel).
    case cancelHostPairing
    case selectHost(HostID)
    case selectDirectoryView(DirectoryView)
    case selectConversation(SessionID)
    case openNewChat
    case returnHome
    case openSettings
    case closeSettings
    case search(String)
    case clearSearch
    case loadMoreDirectory(DirectoryCollection)
    case refreshDirectoryView(DirectoryCollection)
    case pageOlderTranscript
    case editDraftText(String)
    case addDraftAttachment(AttachmentDraftInput)
    case removeDraftAttachment(AttachmentID)
    case retryAttachmentUpload(AttachmentID)
    case downloadAttachment(AttachmentID)
    case selectAgent(AgentID)
    case selectModel(String?)
    case selectWorkspace(WorkspaceID)
    case selectTask(TaskID?)
    case send
    case stop
    case recoverUncertainOperation
    case retryUncertainCreate
    case respondToInteraction(InteractionID, actionID: ActionID, values: [String: InteractionValue])
    case setAutoTranslation(enabled: Bool)
    case requestReadingTranslation(sourceID: String, text: String)
    case cancelReadingTranslation(sourceID: String)
    case retryTranslationText(TranslationRecordID)
    case retryTranslationSend
    case sendOriginal
    case reclaimTranslationDraft
    case dismissBanner(BannerID)
    case openBanner(BannerID)
    case noteLocalConnectivity(LocalConnectivity)
    case setForeground(ForegroundPresence)
    case refreshDirectory
    case clearAttachmentCache
    /// Reads an Agent's conversation options (`catalog.agent`).
    case loadAgentOptions(AgentID)
    /// Fetches each known Agent's own logo from the Host (`proxy.logo`).
    case loadAgentLogos
    /// Changes the open conversation (`session.update`); applies next turn.
    case setConversationModel(String?)
    case setConversationThinking(String?)
    case setConversationFast(Bool)
    case setConversationApprovalMode(String?)
    /// New-chat options, sent with or right after creation.
    case selectThinking(String?)
    case selectFast(Bool)
    case selectApprovalMode(String?)
}
