import AppKit
import os
import Shared

/// The agent's tools (M5): the reference library, app dictionaries, installed apps and
/// shortcuts, permission checks, reading automations, and drafts.
extension RunnerCore {
    var drafts: DraftStore { DraftStore(directory: store.draftsDirectory) }

    // MARK: Commands

    func handleAgentCommand(_ command: RunnerCommand) async -> RunnerReply {
        do {
            switch command {
            case .searchReference(let query, let limit):
                return .referenceHits(try await reference.search(query, limit: limit))
            case .readReference(let id):
                guard let chunk = try await reference.read(id: id) else {
                    return .failure("No reference chunk has the id \"\(id)\". Use search_reference to find ids.")
                }
                return .referenceChunk(chunk)
            case .introspectApp(let app, let query):
                let hint = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
                return .appDictionary(try await reference.introspect(app: app, query: query, hint: hint))
            case .listApps:
                return .apps(await listApps())
            case .listShortcuts:
                return try await listShortcuts()
            case .checkPermissions(let permissions):
                return .permissions(await PermissionChecker.check(permissions))
            case .readAutomation(let id):
                return readAutomation(id: id)
            default:
                return .failure("The runner cannot handle this command here.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func handleDraftCommand(_ command: RunnerCommand) async -> RunnerReply {
        switch command {
        case .writeDraft(let manifestData, let files):
            return writeDraft(manifestData: manifestData, files: files)
        case .validateDraft(let id):
            return await validateDraft(id: id)
        case .installDraft(let id):
            return await installDraft(id: id)
        case .discardDraft(let id):
            do {
                try drafts.remove(id: id)
                return .done
            } catch {
                return .failure(error.localizedDescription)
            }
        default:
            return .failure("The runner cannot handle this command here.")
        }
    }

    // MARK: Apps, shortcuts, automations

    private func listApps() async -> [AppInfo] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return await reference.scanApps().map { app in
            AppInfo(
                name: app.name, bundleID: app.bundleID, path: app.url.path,
                scriptable: app.scriptable, running: running.contains(app.bundleID)
            )
        }
    }

    private func listShortcuts() async throws -> RunnerReply {
        let result = try await ScriptRunner.runTool("/usr/bin/shortcuts", arguments: ["list"], timeout: 20)
        if result.timedOut { return .failure("shortcuts list timed out.") }
        guard result.exitCode == 0 else {
            let reason = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("shortcuts list failed: \(reason.isEmpty ? "status \(result.exitCode)" : reason)")
        }
        let names = result.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return .shortcuts(names)
    }

    private func readAutomation(id: String) -> RunnerReply {
        guard let manifest = manifests[id], let summary = summaries().first(where: { $0.id == id }) else {
            return .failure("\(id) is not installed.")
        }
        let folder = store.folder(for: id)
        let manifestJSON = (try? String(contentsOf: folder.appending(path: "manifest.json"), encoding: .utf8))
            ?? (try? manifest.encoded()).flatMap { String(bytes: $0, encoding: .utf8) }
            ?? "{}"
        return .automation(AutomationDetail(
            summary: summary, manifestJSON: manifestJSON, files: FolderText.textFiles(in: folder)
        ))
    }

    // MARK: Drafts

    private func writeDraft(manifestData: Data, files: [DraftFile]) -> RunnerReply {
        let manifest: AutomationManifest
        do {
            manifest = try AutomationManifest.decode(from: manifestData)
        } catch {
            return .failure("The manifest could not be read: \(Self.describe(error))")
        }
        do {
            let folder = try drafts.write(manifest, files: files)
            return .draftWritten(id: manifest.id, issues: ManifestValidator.validate(manifest, folder: folder))
        } catch {
            return .failure("Could not write the draft: \(error.localizedDescription)")
        }
    }

    private func draftManifest(id: String) -> Result<AutomationManifest, DraftReadError> {
        do {
            let manifest = try drafts.manifest(id: id)
            guard manifest.id == id else {
                let message = "The draft folder \(id) holds a manifest with id \(manifest.id)."
                return .failure(DraftReadError(message: message))
            }
            return .success(manifest)
        } catch {
            return .failure(DraftReadError(message: Self.describe(error)))
        }
    }

    /// Static, compile, unit and harness checks against the draft's folder. Harness runs are
    /// logged (cause `test`) under the draft's id.
    private func validateDraft(id: String) async -> RunnerReply {
        switch draftManifest(id: id) {
        case .failure(let problem):
            return .failure(problem.message)
        case .success(let manifest):
            return .draftValidated(await test(manifest, folder: drafts.folder(for: id), postsHotkeys: false))
        }
    }

    /// Installs through the normal path (validate, compile, commit, register), then deletes
    /// the draft if that worked.
    private func installDraft(id: String) async -> RunnerReply {
        if case .failure(let problem) = draftManifest(id: id) { return .failure(problem.message) }
        let data: Data
        do {
            data = try drafts.manifestData(id: id)
        } catch {
            return .failure(error.localizedDescription)
        }
        let report = await install(manifestData: data, sourceFolder: drafts.folder(for: id))
        if report.installed {
            do {
                try drafts.remove(id: id)
            } catch {
                let problem = error.localizedDescription
                logger.error("Installed \(id, privacy: .public); its draft stays: \(problem, privacy: .public)")
            }
        }
        return .installed(report)
    }

    // MARK: Reference library

    /// Builds the library in the background now and every six hours, so new and updated apps
    /// get their dictionaries read.
    func startReferenceLibrary() {
        referenceRefresh?.cancel()
        state.referenceStatus = "Reference library: building…"
        let bundled = Bundle.main.url(forResource: "Reference", withExtension: nil)
        let reference = self.reference
        referenceRefresh = Task { [weak self] in
            while !Task.isCancelled {
                let examples = self?.referenceExamples() ?? []
                let status = await reference.build(bundled: bundled, examples: examples)
                self?.state.referenceStatus = status.menuLine
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    /// Re-indexes the installed automations as worked examples.
    func refreshReferenceExamples() {
        guard referenceRefresh != nil else { return }
        let examples = referenceExamples()
        let reference = self.reference
        Task { [weak self] in
            let status = await reference.updateExamples(examples)
            if !status.building { self?.state.referenceStatus = status.menuLine }
        }
    }

    func referenceExamples() -> [ReferenceExample] {
        manifests.values.sorted { $0.id < $1.id }.map { manifest in
            let folder = store.folder(for: manifest.id)
            let json = (try? String(contentsOf: folder.appending(path: "manifest.json"), encoding: .utf8)) ?? ""
            return ReferenceExample(manifest: manifest, manifestJSON: json, files: FolderText.textFiles(in: folder))
        }
    }
}

/// Why a draft's manifest could not be used.
struct DraftReadError: Error {
    var message: String
}
