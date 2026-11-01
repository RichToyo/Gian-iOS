import Foundation

public enum GianClientAction: Sendable {
    case setServerAddress(String)
    case startGitHubDeviceLogin
    case pollGitHubDeviceLogin
    case cancelGitHubDeviceLogin
    case logout
    case beginHostPairingFromQR(String)
    case refreshHostPairing
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
}
