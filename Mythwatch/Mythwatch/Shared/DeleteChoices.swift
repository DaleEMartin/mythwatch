import SwiftUI

/// The buttons of every delete dialog: both re-record choices (owner, 2026-11-15: ask each time)
/// and a way out. `allowRerecord` goes straight to the model's delete.
struct DeleteChoices: View {
    var cancelTitle: String = Labels.cancel
    let delete: (_ allowRerecord: Bool) -> Void
    var cancel: () -> Void = {}

    var body: some View {
        Button(Labels.delete, role: .destructive) { delete(false) }
            .accessibilityIdentifier("delete.noRerecord")
        Button(Labels.deleteAndRerecord, role: .destructive) { delete(true) }
            .accessibilityIdentifier("delete.rerecord")
        Button(cancelTitle, role: .cancel) { cancel() }
    }
}

/// The dialog's message: the warning when the viewer asked to be asked (`askBeforeDelete`),
/// and the re-record choice always.
enum DeleteMessage {
    static func text(confirming: Bool) -> String {
        confirming ? "\(Labels.deleteDetail) \(Labels.rerecordDetail)" : Labels.rerecordDetail
    }
}
