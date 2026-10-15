import Foundation

/// Deciding what a save does: write over the file, warn first that the
/// file holds content SimpleSpread can't write back, or ask where to save.
/// Each platform adds its own prompts (Mac/SavePrompt.swift, iOS/).
@MainActor
enum DocumentSaving {
    /// What a save does next.
    enum SavePlan: Equatable {
        /// Write over the document's file.
        case write(URL)
        /// Ask first: writing over the file would remove `items`.
        case confirmLoss(URL, [String])
        /// Ask for a location; `lossNote` (shown in the panel) says what the
        /// new file will not have.
        case choose(lossNote: String?)
    }

    static func plan(for document: SpreadsheetDocument, as forceAs: Bool = false) -> SavePlan {
        let lost = document.unsupportedContentAccepted ? [] : document.unsupportedContent
        if let url = document.fileURL, !forceAs {
            return lost.isEmpty ? .write(url) : .confirmLoss(url, lost)
        }
        // Save As leaves the original alone, so it only says what the copy
        // lacks; once saved, the document is that copy and nothing is lost.
        return .choose(lossNote: lost.isEmpty ? nil : lossNote(document, lost))
    }

    static func lossNote(_ document: SpreadsheetDocument, _ items: [String]) -> String {
        "This copy won’t include the \(list(items)) from “\(document.saveFileName)”, "
            + "which SimpleSpread can’t save. The original file is not changed."
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// "Budget.xlsx" -> "Budget copy.xlsx".
    static func copyName(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base + " copy.xlsx"
    }
}
