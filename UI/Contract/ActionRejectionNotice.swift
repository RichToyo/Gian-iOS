import GianCore

/// A short reason for a tap the store refused, so a tap never just does
/// nothing. Only for actions the user started; background reads stay quiet,
/// and reasons the screen already shows (the composer's notices, a card that
/// changed) aren't repeated.
enum ActionRejectionNotice {
    static func message(for action: GianClientAction, code: RejectionCode) -> String? {
        guard isUserCommand(action) else { return nil }
        switch code {
        case .offlineDraftRetained, .uncertainOutcome, .emptyDraft, .staleOperation, .scopeMismatch,
             .interactionNotPending, .invalidServerAddress, .serverIdentityChanged, .pairingQRInvalid,
             .pairingServerMismatch:
            return nil
        case .mutationsDisabled: return "Still syncing with the Host. Try again in a moment."
        case .operationInFlight: return "The previous request is still on its way."
        case .notAuthorized, .noCurrentHost: return "Not connected to a Host."
        case .missingTask: return "Choose a Task first."
        case .missingAgent: return "Choose an Agent first."
        case .missingWorkspace: return "Choose a repository first."
        case .missingCatalog: return "Agents and repositories are still loading."
        case .attachmentRejected:
            return "That file can't be attached. Files must be 20 MB or smaller."
        case .capabilityDenied: return "The Host doesn't allow this from a remote device."
        case .capabilityUnsupported, .legacyTasklessCreateUnsupported, .legacyReposUnsupported, .legacySearchUnsupported:
            return "The Host doesn't support this. Updating Gian on the Host may help."
        case .translationUnavailable: return "Translation isn't available on this Host."
        case .translationNotConfigured: return "Translation isn't set up on the Host."
        case .unknownActionID, .unknownInputID: return "That choice is no longer offered."
        case .notFound: return "That is no longer available."
        }
    }

    static func isUserCommand(_ action: GianClientAction) -> Bool {
        switch action {
        case .send, .stop, .mutateQueue, .respondToInteraction, .addDraftAttachment, .retryAttachmentUpload,
             .downloadAttachment, .setConversationModel, .setConversationThinking, .setConversationFast,
             .setConversationApprovalMode, .setAutoTranslation, .requestReadingTranslation, .retryTranslationText,
             .retryTranslationSend, .sendOriginal, .retryUncertainCreate, .pageOlderTranscript:
            return true
        default:
            return false
        }
    }
}
