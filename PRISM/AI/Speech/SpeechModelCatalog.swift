// SpeechModelCatalog.swift
// PRISM
//
// Which speech models PRISM offers, what they cost to download, and where
// they are kept (§5.32).
//
// The sizes are here rather than fetched, and they are stated in the UI
// before anything starts, because the first run of this feature asks the
// user to download more data than the whole application. A progress bar
// that appears after the decision has been made is not consent.
//
// `base.en` is the default, not the best model available. 147 MB is a
// download somebody will actually agree to; 627 MB is one they will
// cancel, and a cancelled download is a feature that never worked. The
// large model is one picker row away for anyone who wants it.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public enum SpeechModelCatalog {

    /// Argmax's Core ML conversions on Hugging Face. The only host PRISM
    /// ever downloads from, and the download happens once.
    public static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// Where models live: `~/Library/Application Support/PRISM/Models`.
    ///
    /// Overriding this is not optional. WhisperKit's vendored Hub client
    /// defaults to `~/Documents/huggingface`, so leaving `downloadBase` nil
    /// drops several hundred megabytes into the user's literal Documents
    /// folder, where it syncs to iCloud and where nobody will ever work out
    /// what put it there.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PRISM", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The models offered, cheapest first.
    ///
    /// English-only variants are listed first and one is the default: a
    /// `.en` model is both smaller and more accurate on English than the
    /// multilingual model of the same size, and the multilingual one will
    /// occasionally decide a quiet English sentence is Welsh.
    public static let all: [SpeechModel] = [
        SpeechModel(
            variant: "openai_whisper-base.en",
            shortName: "base.en",
            displayName: "Base (English)",
            megabytes: 147,
            detail: "The default. Fast enough to keep up on any Apple Silicon Mac."),
        SpeechModel(
            variant: "openai_whisper-small.en",
            shortName: "small.en",
            displayName: "Small (English)",
            megabytes: 483,
            detail: "Noticeably better on names and technical words. Still comfortably real time."),
        SpeechModel(
            variant: "openai_whisper-large-v3-v20240930_626MB",
            shortName: "large-v3",
            displayName: "Large (all languages)",
            megabytes: 627,
            detail: "The most accurate, and the only one that handles languages other than English."),
    ]

    public static let defaultModel = "base.en"

    /// Resolves a stored short name. An unknown one — a settings file from a
    /// build that offered a model this one does not — falls back rather than
    /// failing, because the alternative is a feature that cannot start and
    /// cannot say why.
    public static func model(named shortName: String) -> SpeechModel {
        all.first { $0.shortName == shortName }
            ?? all.first { $0.shortName == defaultModel }
            ?? all[0]
    }

    /// Whether a variant is already on disk, so the UI can say "Download"
    /// or just start.
    ///
    /// Checks for the variant's directory containing at least one compiled
    /// Core ML model. A directory that exists but is empty is a download
    /// that was interrupted, and treating it as present is how a feature
    /// hangs on first use instead of resuming.
    public static func isDownloaded(_ model: SpeechModel) -> Bool {
        let folder = directory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelRepo, isDirectory: true)
            .appendingPathComponent(model.variant, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: folder.path) else { return false }
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    /// Total bytes currently occupied by downloaded models, for the pane's
    /// "and here is how to get it back" row.
    public static func bytesOnDisk() -> Int64 {
        let root = directory
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Deletes every downloaded model. The user asked; there is nothing
    /// here that cannot be downloaded again.
    public static func removeAll() throws {
        let root = directory
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// Human-readable size, matching the register the rest of the app uses.
    public static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
