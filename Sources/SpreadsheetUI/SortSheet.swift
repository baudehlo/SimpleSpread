import SwiftUI
import SpreadsheetCore

/// Data ▸ Custom Sort…: up to three sort levels over the selection (or the
/// data around the cursor), with a "has header row" choice.
struct SortSheet: View {
    @ObservedObject var document: SpreadsheetDocument
    @Environment(\.dismiss) private var dismiss

    struct Level: Identifiable {
        let id = UUID()
        var column: Int
        var ascending = true
    }

    @State private var range: CellRange?
    @State private var hasHeader = false
    @State private var levels: [Level] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sort").font(.headline)
            if let range {
                Text("Range \(range.a1)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("My data has a header row", isOn: $hasHeader)
                ForEach($levels) { $level in
                    HStack {
                        Text(level.id == levels.first?.id ? "Sort by" : "Then by")
                            .frame(width: 60, alignment: .leading)
                        Picker("", selection: $level.column) {
                            ForEach(range.start.column...range.end.column, id: \.self) { column in
                                Text(columnTitle(column, in: range)).tag(column)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Picker("", selection: $level.ascending) {
                            Text("A to Z").tag(true)
                            Text("Z to A").tag(false)
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Button {
                            levels.removeAll { $0.id == level.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(levels.count == 1)
                    }
                }
                Button("Add Level") {
                    levels.append(Level(column: range.start.column))
                }
                .disabled(levels.count >= 3)
            } else {
                Text("Select the data to sort first.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sort") {
                    if let range {
                        document.sort(range: range,
                                      keys: levels.map { SortKey(column: $0.column, ascending: $0.ascending) },
                                      hasHeader: hasHeader)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(range == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let target = document.sortTarget() {
                range = target.range
                hasHeader = target.hasHeader
                let column = min(max(document.selection.activeCell.column, target.range.start.column),
                                 target.range.end.column)
                levels = [Level(column: column)]
            }
        }
    }

    /// "Column B", or with a header row, the header's text.
    private func columnTitle(_ column: Int, in range: CellRange) -> String {
        let name = "Column \(CellAddress.columnName(column))"
        guard hasHeader else { return name }
        let header = document.displayString(at: CellAddress(row: range.start.row, column: column))
        return header.isEmpty ? name : header
    }
}
