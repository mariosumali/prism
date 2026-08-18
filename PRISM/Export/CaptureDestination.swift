// CaptureDestination.swift
// PRISM
//
// Where a saved still or clip lands, and what it is called (§5.15, §5.16).
// One folder serves both features: a user who has pointed PRISM at a folder
// has pointed it there once, not twice, and two destinations would mean two
// places to look for the thing you just saved.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// Why a capture could not be written, in the sentence the user is shown.
/// Every case reads as a whole line of UI copy rather than an error code,
/// because that is exactly where they end up (§8.4).
public enum CaptureError: LocalizedError, Equatable {
    case folderUnavailable(String)
    case nothingBuffered
    case noPicture
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable(let path):
            return "PRISM can't write to \(path). Choose another folder."
        case .nothingBuffered:
            return "Nothing buffered to save yet"
        case .noPicture:
            return "There is no picture to save yet"
        case .encodingFailed(let reason):
            return "Couldn't finish writing the file — \(reason)"
        }
    }
}

public enum CaptureDestination {

    /// What is being written. The two prefixes mirror the system's own
    /// screenshot and screen-recording names, so a folder holding both sorts
    /// into two runs rather than interleaving stills and clips by second.
    public enum Kind {
        case still
        case clip

        var prefix: String {
            switch self {
            case .still: return "PRISM"
            case .clip: return "PRISM Clip"
            }
        }
    }

    /// The macOS screenshot convention: prefix, ISO date, "at", and a
    /// dot-separated wall clock. Fixed locale and POSIX calendar — a file
    /// name is an identifier, and one that changes shape with the user's
    /// region is one that cannot be sorted, scripted, or recognised.
    public static func fileName(kind: Kind, date: Date, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(kind.prefix) \(formatter.string(from: date)).\(fileExtension)"
    }

    /// A name in `folder` that is not taken, disambiguated the way macOS
    /// disambiguates a second screenshot inside the same second.
    ///
    /// `exists` is injected so the whole naming path is testable without
    /// touching a disk; the default is the obvious one.
    public static func uniqueURL(in folder: URL, fileName: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let candidate = folder.appendingPathComponent(fileName)
        guard exists(candidate) else { return candidate }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        // Two captures inside one second is the only realistic collision, so
        // the search is bounded rather than clever; past the bound the caller
        // gets a name that will overwrite, which is still better than a hang.
        for index in 2...99 {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let url = folder.appendingPathComponent(name)
            if !exists(url) { return url }
        }
        return candidate
    }

    /// Creates the destination if it is missing and proves it writable
    /// *before* anything is encoded. A capture that fails after the work is
    /// done has already cost the user the moment it was trying to keep.
    public static func prepare(_ folder: URL) throws -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CaptureError.folderUnavailable(folder.path)
            }
        } else {
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw CaptureError.folderUnavailable(folder.path)
            }
        }
        guard manager.isWritableFile(atPath: folder.path) else {
            throw CaptureError.folderUnavailable(folder.path)
        }
        return folder
    }
}
