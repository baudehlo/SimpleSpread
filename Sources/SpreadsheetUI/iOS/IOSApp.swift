#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os
import SpreadsheetCore

/// Opening, creating and closing documents, for Console.
let documentLog = Logger(subsystem: "com.kikiplan.simplespread", category: "documents")

public enum SimpleSpreadApp {
    @MainActor
    public static func run() {
        SimpleSpreadAppMain.main()
    }
}

/// The iPad app: each window starts at the document browser (Files: iCloud
/// Drive, On My iPad, other providers); a picked spreadsheet opens full
/// screen over it and saves itself as it changes.
struct SimpleSpreadAppMain: App {
    init() {
        FontChoices.prepare()
    }

    var body: some Scene {
        WindowGroup {
            DocumentBrowserScreen()
        }
        .commands {
            FileCommands()
            EditCommands()
            ViewCommands()
            InsertCommands()
            DataCommands()
            FormatCommands()
        }
    }
}

// MARK: - Browser

/// One window's browser and the document open over it.
@MainActor
final class BrowserModel: ObservableObject {
    @Published var session: OpenFile?
    weak var browser: UIDocumentBrowserViewController?
    /// URLs to open once the browser exists (a launch from the Files app).
    private var pending: [URL] = []

    static let openableTypes: [UTType] = [xlsxType, .commaSeparatedText, .tabSeparatedText]

    func attach(_ browser: UIDocumentBrowserViewController) {
        self.browser = browser
        let waiting = pending
        pending = []
        for url in waiting { openExternal(url) }
        let env = ProcessInfo.processInfo.environment
        if let path = env["SIMPLESPREAD_OPEN"] {
            // As on the Mac: open a file at launch (UI tests).
            open(URL(fileURLWithPath: path))
        } else if waiting.isEmpty, env["SIMPLESPREAD_DEMO"] != nil {
            openDemo()
        }
    }

    /// A file handed over by another app or the Files app.
    func openExternal(_ url: URL) {
        guard let browser else {
            pending.append(url)
            return
        }
        browser.revealDocument(at: url, importIfNeeded: true) { [weak self] revealed, error in
            MainActor.assumeIsolated {
                if let revealed {
                    self?.open(revealed)
                } else {
                    Alerts.show("Can’t open “\(url.lastPathComponent)”", detail: error?.localizedDescription ?? "")
                }
            }
        }
    }

    /// Open a spreadsheet, or convert a CSV to one, closing whatever is open.
    func open(_ url: URL) {
        documentLog.info("open \(url.lastPathComponent, privacy: .private)")
        if let current = session {
            current.close { [weak self] closed in
                if closed { self?.open(url) }
            }
            return
        }
        if SpreadsheetDocument.textImportExtensions.contains(url.pathExtension.lowercased()) {
            importText(url)
        } else {
            openSpreadsheet(url)
        }
    }

    private func openSpreadsheet(_ url: URL) {
        let file = SpreadsheetFile(fileURL: url)
        // Files from other apps' places (iCloud Drive, a picker) are reached
        // through security-scoped access, held while the file is open.
        file.scopedAccess = url.startAccessingSecurityScopedResource()
        let progress = TaskProgress(fileName: url.lastPathComponent, title: LoadPhase.reading.title)
        let session = ProgressSession(progress: progress, panelTitle: "Opening \(url.lastPathComponent)", window: nil)
        progress.cancel = {
            file.cancellation.cancel()
            session.finish()
        }
        let throttle = ProgressThrottle<LoadPhase>()
        file.loadProgress = { fraction, phase in
            guard throttle.shouldReport(fraction, phase) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    progress.fraction = fraction
                    progress.title = phase.title
                }
            }
        }
        session.showAfterDelay()
        let opening = Unchecked(file)
        file.open { [weak self] ok in
            onMain {
                let file = opening.value
                session.finish()
                if file.cancellation.isCancelled {
                    if ok { file.close() }
                    return
                }
                guard ok, let document = file.takeDocument() else {
                    documentLog.error("open failed: \(file.lastError?.localizedDescription ?? "?", privacy: .public)")
                    if !(file.lastError is CancellationError) {
                        Alerts.show("Could not open \(url.lastPathComponent)",
                                    detail: file.lastError?.localizedDescription ?? "")
                    }
                    return
                }
                self?.show(OpenFile(file: file, document: document, browser: self))
            }
        }
    }

    /// A CSV opens as a new spreadsheet beside it (never written back over
    /// the text file, as on the Mac), then that spreadsheet is opened.
    private func importText(_ url: URL) {
        FileLoader.open(url) { [weak self] document in
            let name = url.deletingPathExtension().lastPathComponent + ".xlsx"
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let target = temp.appendingPathComponent(name)
            let snapshot = document.makeSaveSnapshot()
            BackgroundFileTask.run(
                title: "Converting…", panelTitle: "Opening \(url.lastPathComponent)", fileName: name, window: nil,
                work: { progress, shouldContinue in
                    try SpreadsheetDocument.write(snapshot, to: target, progress: { progress($0) },
                                                  shouldContinue: shouldContinue)
                },
                completion: { result in
                    switch result {
                    case .success:
                        self?.place(target, nextTo: url)
                    case .failure(let error) where error is CancellationError:
                        break
                    case .failure(let error):
                        Alerts.show("Could not open \(url.lastPathComponent)", detail: error.localizedDescription)
                    }
                })
        }
    }

    /// Put a new file beside `neighbour` (or, where that isn't allowed, in
    /// SimpleSpread's own folder) and open it.
    private func place(_ file: URL, nextTo neighbour: URL) {
        guard let browser else { return }
        browser.importDocument(at: file, nextToDocumentAt: neighbour, mode: .move) { [weak self] placed, error in
            MainActor.assumeIsolated {
                if let placed {
                    self?.open(placed)
                    return
                }
                // A read-only folder: keep it in On My iPad › SimpleSpread.
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let target = Self.unusedURL(for: file.lastPathComponent, in: documents)
                do {
                    try FileManager.default.moveItem(at: file, to: target)
                    self?.open(target)
                } catch {
                    Alerts.show("Could not open \(neighbour.lastPathComponent)", detail: error.localizedDescription)
                }
            }
        }
    }

    /// "Name.xlsx", or "Name 2.xlsx"… if that's taken.
    static func unusedURL(for fileName: String, in directory: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// A blank workbook for the browser's create button.
    static func makeBlankFile() throws -> URL {
        // A replacement directory (not a plain temporary one): the browser's
        // import of a plain temporary file fails with DocumentManager error 1.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let temp = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: documents, create: true)
        let url = temp.appendingPathComponent("Untitled.xlsx")
        try SpreadsheetDocument().save(to: url)
        return url
    }

    /// `SIMPLESPREAD_DEMO`: open the sample sheet (screenshots).
    private func openDemo() {
        let document = SpreadsheetDocument()
        DocumentStore.seedDemoContent(document)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Budget.xlsx")
        let file = SpreadsheetFile(fileURL: url)
        file.adopt(document)
        show(OpenFile(file: file, document: document, browser: self))
    }

    private func show(_ file: OpenFile) {
        session = file
    }

    /// The open document closed (back to the browser).
    func closed(_ file: OpenFile) {
        if session === file { session = nil }
    }
}

/// The window's root: the document browser, with the open document full
/// screen over it.
struct DocumentBrowserScreen: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        DocumentBrowser(model: model)
            .ignoresSafeArea()
            .fullScreenCover(item: $model.session) { session in
                EditorScreen(session: session)
            }
            .onOpenURL { model.openExternal($0) }
            .overlay { ProgressOverlay() }
            // A new window takes the app's appearance choice.
            .onAppear { AppearanceSetting.shared.apply() }
    }
}

struct DocumentBrowser: UIViewControllerRepresentable {
    let model: BrowserModel

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: BrowserModel.openableTypes)
        browser.allowsDocumentCreation = true
        browser.allowsPickingMultipleItems = false
        browser.localizedCreateDocumentActionTitle = "New Spreadsheet"
        browser.delegate = context.coordinator
        DispatchQueue.main.async { model.attach(browser) }
        return browser
    }

    func updateUIViewController(_ browser: UIDocumentBrowserViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIDocumentBrowserViewControllerDelegate {
        let model: BrowserModel

        init(model: BrowserModel) {
            self.model = model
        }

        /// When the last create was asked for (see failedToImportDocumentAt).
        private var creationRequested = Date.distantPast

        func documentBrowser(_ controller: UIDocumentBrowserViewController,
                             didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
            documentLog.info("create requested")
            creationRequested = Date()
            do {
                importHandler(try BrowserModel.makeBlankFile(), .copy)
            } catch {
                importHandler(nil, .none)
                Alerts.show("Couldn’t create a spreadsheet", detail: error.localizedDescription)
            }
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { model.open(url) }
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL,
                             toDestinationURL destinationURL: URL) {
            documentLog.info("created")
            model.open(destinationURL)
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL,
                             error: Error?) {
            documentLog.error("create failed: \(String(describing: error), privacy: .public)")
            // Creating from Recents, with no iCloud Drive to put it in, the
            // browser puts the new file in On My iPad › SimpleSpread and then
            // reports DocumentManager error 1. Open the file it made (or
            // make one there ourselves).
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let made = (try? FileManager.default.contentsOfDirectory(
                at: documents, includingPropertiesForKeys: [.creationDateKey]))?
                .filter { $0.pathExtension == "xlsx" }
                .compactMap { url -> (URL, Date)? in
                    guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                          created >= creationRequested.addingTimeInterval(-1) else { return nil }
                    return (url, created)
                }
                .max { $0.1 < $1.1 }?.0
            if let made {
                model.open(made)
                return
            }
            do {
                let target = BrowserModel.unusedURL(for: "Untitled.xlsx", in: documents)
                try SpreadsheetDocument().save(to: target)
                model.open(target)
            } catch {
                Alerts.show("Couldn’t create a spreadsheet", detail: error.localizedDescription)
            }
        }
    }
}

// MARK: - Open document

/// A document open in a window: its file, and the commands that need the
/// file (saving, copies, CSV in and out, closing).
@MainActor
final class OpenFile: ObservableObject, Identifiable {
    let file: SpreadsheetFile
    @Published private(set) var document: SpreadsheetDocument
    private weak var browser: BrowserModel?
    /// The user has been asked (once) about content saving would remove.
    private var askedAboutLoss = false
    private var closing = false

    init(file: SpreadsheetFile, document: SpreadsheetDocument, browser: BrowserModel?) {
        self.file = file
        self.document = document
        self.browser = browser
        file.onReload = { [weak self] reloaded in
            self?.document = reloaded
        }
    }

    var displayName: String { document.displayName }

    /// The file holds content saving would remove and the user hasn't
    /// agreed to lose it.
    private var savingLosesContent: Bool { !SpreadsheetFile.maySave(document) }

    /// The document changed: the first change to a file whose content
    /// saving would remove asks what to do.
    func documentChanged() {
        file.refreshSaveState()
        guard document.isModified, savingLosesContent, !askedAboutLoss else { return }
        askedAboutLoss = true
        let alert = UIAlertController(
            title: "“\(displayName)” has content SimpleSpread can’t save",
            message: "Saving your changes will remove its \(DocumentSaving.list(document.unsupportedContent)). "
                + "Save them to a copy to keep the original as it is. Until you choose, nothing is saved.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Save a Copy…", style: .default) { [weak self] _ in
            self?.saveCopy(switching: true)
        })
        alert.addAction(UIAlertAction(title: "Save Changes Anyway", style: .destructive) { [weak self] _ in
            self?.acceptLoss()
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        Alerts.present(alert)
    }

    private func acceptLoss() {
        document.acceptUnsupportedContentLoss()
        file.refreshSaveState()
    }

    /// ⌘S: save now (it saves by itself anyway).
    func save() {
        document.commitPendingEdit()
        guard !savingLosesContent else {
            askedAboutLoss = false
            documentChanged()
            return
        }
        file.refreshSaveState()
        file.save(to: file.fileURL, for: .forOverwriting) { ok in
            if !ok {
                Alerts.show("Could not save", detail: self.file.lastError?.localizedDescription ?? "")
            }
        }
    }

    /// Back to the browser, saving first. Asks if saving would remove
    /// content. `completion(true)` once closed.
    func close(_ completion: @escaping (Bool) -> Void = { _ in }) {
        guard !closing else { return }
        document.commitPendingEdit()
        file.refreshSaveState()
        if document.isModified, savingLosesContent {
            let alert = UIAlertController(
                title: "Save the changes to “\(displayName)”?",
                message: "Saving will remove its \(DocumentSaving.list(document.unsupportedContent)), which SimpleSpread can’t save.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Save a Copy…", style: .default) { [weak self] _ in
                self?.saveCopy(switching: false) { saved in if saved { self?.finishClose(completion) } }
            })
            alert.addAction(UIAlertAction(title: "Save Anyway", style: .destructive) { [weak self] _ in
                self?.acceptLoss()
                self?.finishClose(completion)
            })
            alert.addAction(UIAlertAction(title: "Don’t Save", style: .destructive) { [weak self] _ in
                self?.finishClose(completion)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
            Alerts.present(alert)
            return
        }
        finishClose(completion)
    }

    private func finishClose(_ completion: @escaping (Bool) -> Void) {
        closing = true
        let finish = { [weak self] in
            guard let self else { return }
            self.browser?.closed(self)
            completion(true)
        }
        guard file.documentState != .closed else { return finish() }
        file.close { ok in
            MainActor.assumeIsolated {
                if !ok {
                    Alerts.show("Could not save “\(self.displayName)”",
                                detail: self.file.lastError?.localizedDescription ?? "")
                }
                finish()
            }
        }
    }

    /// Write the document to a new file the user places. `switching`: then
    /// edit the copy, leaving the original as it was.
    func saveCopy(switching: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        let snapshot = document.makeSaveSnapshot()
        let name = switching || savingLosesContent
            ? DocumentSaving.copyName(for: document.saveFileName) : document.saveFileName
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let url = temp.appendingPathComponent(name)
        BackgroundFileTask.run(
            title: "Saving…", panelTitle: "Saving “\(name)”", fileName: name, window: nil,
            work: { progress, shouldContinue in
                try SpreadsheetDocument.write(snapshot, to: url, progress: { progress($0) },
                                              shouldContinue: shouldContinue)
            },
            completion: { [weak self] result in
                guard case .success = result else {
                    if case .failure(let error) = result, !(error is CancellationError) {
                        Alerts.show("Could not save", detail: error.localizedDescription)
                    }
                    return completion(false)
                }
                DocumentPicker.export(url) { placed in
                    guard let self, let placed else { return completion(false) }
                    completion(true)
                    if switching {
                        // The edits went to the copy: leave the original as it was.
                        self.finishClose { _ in self.browser?.open(placed) }
                    }
                }
            })
    }

    func importCSV() {
        document.commitPendingEdit()
        DocumentPicker.pick([.commaSeparatedText, .tabSeparatedText, .plainText]) { [weak self] url in
            guard let self, let url else { return }
            BackgroundCSV.importSheet(into: self.document, from: url, in: nil) { error in
                Alerts.show("Could not import CSV", detail: error.localizedDescription)
            }
        }
    }

    func exportCSV() {
        document.commitPendingEdit()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let url = temp.appendingPathComponent(document.activeSheet.name + ".csv")
        BackgroundCSV.exportActiveSheet(of: document, to: url, in: nil, done: {
            DocumentPicker.export(url) { _ in }
        }, failed: { error in
            Alerts.show("Could not export CSV", detail: error.localizedDescription)
        })
    }
}

/// The open document, full screen: a bar with the way back to the browser
/// and the file commands, over the same window content as on the Mac.
struct EditorScreen: View {
    @ObservedObject var session: OpenFile

    var body: some View {
        NavigationStack {
            DocumentWindowView(document: session.document)
                .id(ObjectIdentifier(session.document))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            session.close()
                        } label: {
                            Label("Documents", systemImage: "folder")
                        }
                        .help("Back to your documents (saves)")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Save a Copy…", systemImage: "doc.on.doc") { session.saveCopy(switching: false) }
                            Divider()
                            Button("Import CSV as Sheet…", systemImage: "square.and.arrow.down") { session.importCSV() }
                            Button("Export Sheet as CSV…", systemImage: "square.and.arrow.up") { session.exportCSV() }
                        } label: {
                            Label("File", systemImage: "ellipsis.circle")
                        }
                    }
                }
        }
        .overlay { ProgressOverlay() }
        .onReceive(session.document.$revision) { _ in
            DispatchQueue.main.async { session.documentChanged() }
        }
        .focusedSceneValue(\.openFile, session)
    }
}

// MARK: - Menus

struct OpenFileFocusKey: FocusedValueKey {
    typealias Value = OpenFile
}

extension FocusedValues {
    var openFile: OpenFile? {
        get { self[OpenFileFocusKey.self] }
        set { self[OpenFileFocusKey.self] = newValue }
    }
}

/// File menu commands that need the file: the iPad saves by itself, so
/// these are Save (now), copies, CSV in and out, and Close.
struct FileCommands: Commands {
    @FocusedValue(\.openFile) var session

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Close") { session?.close() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(session == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { session?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(session == nil)
            Button("Save a Copy…") { session?.saveCopy(switching: false) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(session == nil)
            Divider()
            Button("Import CSV as Sheet…") { session?.importCSV() }
                .disabled(session == nil)
            Button("Export Sheet as CSV…") { session?.exportCSV() }
                .disabled(session == nil)
        }
    }
}

// MARK: - Document pickers

/// The system's pickers for choosing a file to read, or a place to put one.
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    private static var active: Set<DocumentPicker> = []
    private let completion: (URL?) -> Void

    private init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
    }

    /// Let the user put `url` somewhere (it is moved there).
    static func export(_ url: URL, completion: @escaping (URL?) -> Void) {
        present(UIDocumentPickerViewController(forExporting: [url], asCopy: false), completion: completion)
    }

    /// Let the user choose a file to read (a copy, so no access to keep).
    static func pick(_ types: [UTType], completion: @escaping (URL?) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        present(picker, completion: completion)
    }

    private static func present(_ picker: UIDocumentPickerViewController, completion: @escaping (URL?) -> Void) {
        let delegate = DocumentPicker(completion: completion)
        active.insert(delegate)
        picker.delegate = delegate
        Alerts.present(picker)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    private func finish(_ url: URL?) {
        completion(url)
        Self.active.remove(self)
    }
}
#endif
