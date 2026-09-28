/// Suppresses a selected-pane alert only while Rai is visible to the user.
enum NotificationDeliveryPolicy {
    static func shouldDeliver(
        paneID: String,
        selectedPaneID: String?,
        raiIsVisible: Bool
    ) -> Bool {
        paneID != selectedPaneID || !raiIsVisible
    }
}
