import SpreadsheetUI

/// The iPad app's entry point. Everything else is in the SpreadsheetUI
/// package target (Sources/SpreadsheetUI/iOS and Shared), as for the Mac.
@main
enum Main {
    static func main() {
        SimpleSpreadApp.run()
    }
}
