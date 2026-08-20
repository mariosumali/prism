// Keychain.swift
// PRISM
//
// The one secret PRISM holds — an AI provider's API key (§5.33) — and the
// only file in this app that talks to the Security framework.
//
// A key is not a setting, and the difference is not pedantry. StudioSettings
// is a JSON blob in a plist under ~/Library/Preferences: any process running
// as this user can read it, with no prompt, no entitlement and no trace. It
// is also the thing PRISM hands out on purpose — settings travel with an
// exported preset, and the diagnostics pane bundles them up for a support
// thread. Put a key in that struct and the credential leaves the machine
// through three separate doors, two of which the user opened themselves
// believing they were sharing a look and a bug report.
//
// The rejected alternative was a file of PRISM's own in Application Support,
// chmod 0600, left out of the export and out of the bundle. That fixes the
// two doors the user opens and none of the rest: 0600 keeps out other users,
// not other processes running as this one, and Time Machine, a synced home
// folder and every backup tool copy it verbatim. The keychain is the only
// store on this system where the secret is encrypted at rest under a key
// PRISM never sees and access is scoped to the signature that wrote it. So
// that is where it goes, and this file stays small enough to read in full
// before trusting it.
//
// Two attributes below do the real work and both look like boilerplate.
// `kSecUseDataProtectionKeychain` selects the modern, access-group-scoped
// keychain instead of the legacy login.keychain file; without it a menu-bar
// agent that reads a key at launch triggers "PRISM wants to access your
// keychain" on every single launch, and a user trained to click Allow on a
// dialog they see daily is a user who will click Allow on the one that
// matters. `kSecAttrAccessibleAfterFirstUnlock` is the accessibility class a
// login item needs: PRISM starts before anyone has touched the machine after
// a reboot, and `WhenUnlocked` would leave the assistant dead until the user
// happened to open Settings and retype something that was never lost.
//
// The consequence worth explaining to users rather than hiding: keychain
// access is tied to the code signature. A fork of PRISM signed with a
// different Team ID genuinely cannot read a key written by the original —
// usually it sees nothing at all, because the data-protection keychain
// partitions items by access group, and on an item carried over from an
// older build it sees `errSecAuthFailed`. Both mean "type it again", which
// is exactly what the error copy says. Nothing in this file logs, and no
// error carries the value; the OSStatus is the most a support thread gets.
//
// There is no Keychain test file, on purpose. These calls need an entitled,
// properly signed test host to do anything but fail, and PRISMTests is
// deliberately ad-hoc signed so the suite runs on any machine that checks
// out the repo. A test here would either skip everywhere or assert that the
// API is unavailable, and neither of those defends anything.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import Security

public enum Keychain {

    /// One service for every AI credential PRISM stores, accounts inside it.
    /// Scoped below the bundle identifier so a future secret that is not an
    /// LLM key gets its own service rather than colliding in this one.
    public static let service = "horse.prism.PRISM.llm"

    /// Which key. The two providers that need one; Ollama and any other
    /// local endpoint do not, which is the point of offering them (§5.33).
    public enum Account {
        public static let anthropic = "anthropic.api-key"
        public static let openAICompatible = "openai-compatible.api-key"
    }

    /// Why the keychain would not cooperate, in the sentence the user is
    /// shown. Whole lines of UI copy rather than error codes, because that
    /// is where they end up — the same discipline as `CaptureError`.
    ///
    /// The OSStatus rides along for a support thread. It never carries the
    /// value and neither does anything else in this file.
    public enum KeychainError: LocalizedError, Equatable {
        /// The store could not be written or cleared at all.
        case unavailable(OSStatus)
        /// An item exists and this build is not allowed to open it.
        case unreadable(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let status):
                return "PRISM couldn't reach the keychain (error \(status)). Your key wasn't changed."
            case .unreadable:
                return "PRISM can't read your saved key — enter it again. A key saved by a differently signed build of PRISM can't be opened by this one."
            }
        }
    }

    // MARK: - Reading

    /// The stored key, or nil when there is none.
    ///
    /// **This blocks the calling thread.** Every SecItem call does; the
    /// keychain is a synchronous XPC round trip to securityd and it is not
    /// fast. Callers read once at launch, hold the string in memory for as
    /// long as the provider is configured, and never touch this per request.
    ///
    /// Failure and absence collapse to nil here on purpose — a caller that
    /// only wants a key to send does not care why it has none. The pane that
    /// has to explain itself calls `read` instead.
    public static func get(account: String) -> String? {
        (try? read(account: account).get()) ?? nil
    }

    /// The stored key, distinguishing "no key" (success, nil) from "there is
    /// a key and this build cannot open it" (failure). Blocks, as above.
    ///
    /// `errSecItemNotFound` is a success: not having configured a provider
    /// is the default state of this app, not an error to report.
    public static func read(account: String) -> Result<String?, KeychainError> {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                // Something is in there and it is not a UTF-8 string, so it
                // is not a key PRISM wrote. Retyping is the only repair.
                return .failure(.unreadable(errSecDecode))
            }
            return .success(value)
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(error(for: status))
        }
    }

    /// Whether a usable key is stored — what the Settings pane asks before
    /// it offers to turn the assistant on.
    ///
    /// This pays for a full read rather than an attributes-only existence
    /// check, because an existence check answers the wrong question: an item
    /// this build is not allowed to decrypt still matches a query that never
    /// asks for its data, and reporting "yes, there is a key" would send the
    /// user off to debug a provider when the fix is to retype the key. An
    /// item that cannot be opened is not a key you have. Blocks, as above.
    public static func has(account: String) -> Bool {
        switch read(account: account) {
        case .success(let value):
            return !(value ?? "").isEmpty
        case .failure:
            return false
        }
    }

    // MARK: - Writing

    /// Stores `value`, replacing whatever was there. Blocks, as above.
    ///
    /// Surrounding whitespace is stripped first: a key arrives by paste far
    /// more often than by typing, and a pasted key carries a trailing
    /// newline often enough to matter. A newline inside an HTTP header value
    /// is header injection in shape if not in intent, and the request would
    /// fail in a way that looks like a bad key rather than a stray byte.
    ///
    /// An empty value deletes instead of storing an empty secret — clearing
    /// the field in the pane and saving is how a user revokes a key, and
    /// leaving a zero-length item behind would mean the keychain says a key
    /// exists while every caller correctly behaves as though none does.
    @discardableResult
    public static func set(_ value: String, account: String) -> Result<Void, KeychainError> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(account: account) }

        // Delete-then-add rather than SecItemUpdate. Update fails with
        // errSecItemNotFound on the first save, so it needs an add path
        // anyway, and an add on top of an existing item fails with
        // errSecDuplicateItem — two code paths, each of which is only
        // exercised by one half of the user population, and the half that
        // never exercises the rarer one is where the bug lives. Deleting
        // first makes both saves the same save.
        let cleared = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch cleared {
        case errSecSuccess, errSecItemNotFound:
            break
        default:
            return .failure(error(for: cleared))
        }

        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        // PRISM is a login item and reads this before anyone has unlocked
        // the machine after a reboot; WhenUnlocked would be a key that is
        // there when you do not need it and gone when you do.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // Explicitly not an iCloud Keychain item. The default is already
        // non-synchronizable, but a credential fanning out to every device
        // on the account is not a thing to leave to a default.
        attributes[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { return .failure(error(for: status)) }
        return .success(())
    }

    /// Forgets the key. Blocks, as above.
    ///
    /// Deleting something that was never there is a success: the caller
    /// asked for a state, not for an event, and that state now holds.
    @discardableResult
    public static func remove(account: String) -> Result<Void, KeychainError> {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return .success(())
        default:
            return .failure(error(for: status))
        }
    }

    // MARK: - Query construction

    /// The attributes that identify our item, shared by every call —
    /// including the delete, which is the one people forget.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Load-bearing. Without this line these calls address the legacy
            // file-based login keychain, whose ACL prompt fires on a
            // background read — meaning "PRISM wants to access your
            // keychain" on every launch of a menu-bar agent that reads its
            // key at startup. It must be on every query, delete included:
            // a delete that omits it looks in the other keychain, finds
            // nothing, and leaves the real item behind.
            kSecUseDataProtectionKeychain as String: true,
        ]
        // kSecAttrAccessible is deliberately absent. It is an attribute of a
        // stored item, not a search term, and including it here would narrow
        // deletes and lookups to items written with exactly that class —
        // silently missing anything an earlier build stored under another.
    }

    /// `errSecAuthFailed` and `errSecInteractionNotAllowed` mean the item is
    /// real and this process is not allowed at it: a differently signed
    /// build, or a keychain that never got unlocked. `errSecMissingEntitlement`
    /// is the local-development shape of the same thing — an ad-hoc signed
    /// binary has no application-identifier and so no access group to be in.
    /// All three are "the key is not available to you"; everything else is
    /// the store itself failing, which is a different sentence.
    private static func error(for status: OSStatus) -> KeychainError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement:
            return .unreadable(status)
        default:
            return .unavailable(status)
        }
    }
}
