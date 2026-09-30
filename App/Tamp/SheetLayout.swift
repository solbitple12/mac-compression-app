import CoreGraphics

/// Shared sizing for Tamp's small dialog sheets (as opposed to the main
/// window or the Preferences window, which size themselves to their own
/// content), so opening one after another doesn't visibly jump in width for
/// no reason tied to what it says.
enum SheetLayout {
    static let padding: CGFloat = 20
    /// A single choice or a short yes/no (the goal picker, naming a preset, a password).
    static let compact: CGFloat = 340
    /// A paragraph of explanation with a couple of buttons (the recommendation
    /// card, a pre-flight question).
    static let standard: CGFloat = 400
    /// Several buttons or a longer decision (the paused-jobs dialog).
    static let wide: CGFloat = 440
}
