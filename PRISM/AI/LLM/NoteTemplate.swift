// NoteTemplate.swift
// PRISM
//
// The shape of a set of meeting notes, held as data rather than as a
// paragraph buried inside a prompt (§5.32).
//
// Ported from Meetily (`Zackriya-Solutions/meeting-minutes`, its
// `Template` / `TemplateSection` model, MIT). The idea taken is small and
// worth naming precisely: a section is a title, an instruction addressed to
// the model, and a shape for the things that go in it — and a note format is
// nothing more than an ordered list of those.
//
// The thesis is that a note format is a preference. Which sections exist,
// what order they come in, whether risks are a section, whether decisions
// are — these are the parts of the output that belong to whoever is going to
// read the notes, and they differ between a design review, a customer call
// and a standup. The alternative, which is what almost every meeting-notes
// feature ships, is one hardcoded prompt string with the headings written
// into it. That costs a release for every "can you put action items at the
// top", and a preference that can only change in a release is a preference
// the user does not have.
//
// The other extreme was rejected too: a free-text box holding the whole
// system prompt. That hands the user the format contract, the grounding
// rules and the injection surface all at once, and the first thing anyone
// does with it is delete the guidelines they did not understand — after
// which the model starts inventing owners for action items and nobody can
// see why. Splitting it here keeps the parts that stop the model lying
// (§5.32's guidelines, the delimiters in Prompts.swift, the output contract)
// under PRISM's control, and gives away the part that was actually the
// user's to begin with.
//
// The action-items row is the one piece of this that is not cosmetic. Its
// `Quoted line` and `Time` columns are Meetily's anti-hallucination trick,
// and they are the cheapest grounding measure found in any of the projects
// researched for §5.32: a model that has to cite the line an action item
// came from cannot invent an owner, because there is no line to put in the
// column. It costs two table columns and it removes the single most common
// way these notes are wrong. Anything else in this file can be edited away;
// that column pair is why the default template has it.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Section

/// One heading in the notes, and what goes under it.
///
/// `id` is the title because the title is what the model is asked to emit as
/// a heading, so two sections sharing one is already a template that cannot
/// produce well-formed notes. Deriving the id from it makes that collision
/// visible in a list rather than hiding it behind a UUID that renders fine.
public struct NoteSection: Codable, Equatable, Identifiable {

    /// Prose under the heading.
    public static let paragraph = "paragraph"
    /// Bullets or rows under the heading.
    public static let list = "list"

    public var id: String { title }

    public var title: String

    /// What the model should put in this section, in the second person.
    public var instruction: String

    /// "paragraph" or "list".
    ///
    /// A string and not an enum, for the same reason the whole file exists.
    /// This value is persisted, shown to the user, and interpolated into a
    /// prompt; a closed enum would mean that adding "table" or "checklist"
    /// later is a schema migration and a release, and it would make a
    /// template written by a newer PRISM undecodable by an older one. The
    /// cost is that an unrecognised value degrades to prose, which is the
    /// harmless direction.
    public var format: String

    /// For list sections, the per-item shape, e.g. a markdown table row.
    public var itemFormat: String?

    public init(title: String, instruction: String, format: String,
                itemFormat: String? = nil) {
        self.title = title
        self.instruction = instruction
        self.format = format
        self.itemFormat = itemFormat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.tolerant(.title, "Notes")
        instruction = c.tolerant(.instruction, "")
        format = c.tolerant(.format, NoteSection.paragraph)
        // An `itemFormat` that decoded to an empty string and one that was
        // absent mean the same thing to every reader below, so they are made
        // the same thing here rather than at four call sites.
        let item = c.tolerant(.itemFormat, "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        itemFormat = item.isEmpty ? nil : item
    }

    /// Unrecognised formats read as prose — see the note on `format`.
    public var isList: Bool {
        format.caseInsensitiveCompare(NoteSection.list) == .orderedSame
    }
}

// MARK: - Template

public struct NoteTemplate: Codable, Equatable, Identifiable {

    public var id: String { name }
    public var name: String
    public var sections: [NoteSection]

    public init(name: String, sections: [NoteSection]) {
        self.name = name
        self.sections = sections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.tolerant(.name, NoteTemplate.standardMeeting.name)
        let decoded = c.tolerant(.sections, [NoteSection]())
        // The empty case is the one that must not survive decoding. A
        // template with no sections produces a prompt with no instructions
        // and a skeleton with no headings, and the model answers that with
        // whatever it feels like — which looks like a model problem and is
        // actually a decoding problem two layers away.
        sections = decoded.isEmpty ? NoteTemplate.standardMeeting.sections : decoded
    }

    // MARK: Rendering

    /// The empty markdown skeleton the model fills in — one h1 per section.
    ///
    /// Handed over in the user message rather than described in prose,
    /// because a model asked to "use these four headings" gets the wording
    /// approximately right and a model handed the headings copies them. That
    /// matters downstream: anything that parses these notes back apart
    /// splits on the headings.
    public func markdownStructure() -> String {
        sections.map { section -> String in
            var block = "# \(section.title)"
            let item = (section.itemFormat ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty {
                block += "\n\n" + item
                // A table header with no delimiter row underneath is not a
                // table in any markdown renderer, and the model copies the
                // skeleton faithfully enough to reproduce the mistake. The
                // rule is synthesised rather than stored so a template author
                // writes the columns they want and nothing else.
                if let rule = NoteTemplate.tableRule(for: item) {
                    block += "\n" + rule
                }
            }
            return block
        }
        .joined(separator: "\n\n")
    }

    /// The "# Section instructions" block of the system prompt.
    ///
    /// Deliberately free of markdown headings. Everything in a prompt that
    /// looks like the output has a way of turning up in the output, and a
    /// block of `##` section names sitting above an instruction to use only
    /// h1 is an invitation to emit h2 headings in the notes.
    public func sectionInstructions() -> String {
        sections.map { section -> String in
            var block = "\(section.title) (\(section.format))"
            let instruction = section.instruction
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !instruction.isEmpty {
                block += "\n" + instruction
            }
            let item = (section.itemFormat ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty {
                block += "\nEach item is one row of exactly this shape, with "
                    + "every column filled in: \(item)"
            }
            return block
        }
        .joined(separator: "\n\n")
    }

    /// `| --- | --- |` sized to a markdown header row, or nil if the string
    /// is not one. Bounded and dumb on purpose: this recognises a pipe table
    /// and nothing else, and anything it does not recognise is passed through
    /// as the literal line the template author wrote.
    static func tableRule(for row: String) -> String? {
        guard row.count > 2, row.hasPrefix("|"), row.hasSuffix("|") else { return nil }
        let columns = row.dropFirst().dropLast()
            .split(separator: Character("|"), omittingEmptySubsequences: false)
            .count
        guard columns > 0 else { return nil }
        return "|" + String(repeating: " --- |", count: columns)
    }

    // MARK: Built-ins

    /// The default, and the one that carries the quoted-line grounding
    /// columns argued for in the header.
    public static let standardMeeting = NoteTemplate(
        name: "Standard meeting",
        sections: [
            NoteSection(
                title: "Summary",
                instruction: """
                    Write what the meeting was about and what came out of it, \
                    in prose. Cover what took real time and skip what took a \
                    sentence. Do not open with a scene-setting line and do not \
                    list who was there.
                    """,
                format: NoteSection.paragraph),
            NoteSection(
                title: "Decisions",
                instruction: """
                    One bullet per decision that was actually settled. Say \
                    what was decided, not what was discussed: talking about \
                    pricing is not a decision, agreeing to hold the price \
                    until the third quarter is. Anything left open belongs \
                    under Open questions instead.
                    """,
                format: NoteSection.list),
            NoteSection(
                title: "Action items",
                instruction: """
                    One row per commitment somebody made out loud. Owner is \
                    the speaker label or a name that was actually said, never \
                    a guess; write Unassigned when the transcript does not \
                    say. Task is the thing to be done, in one line. Due is the \
                    date or deadline that was said, or Not stated. Quoted line \
                    is a short verbatim quote from the transcript that this \
                    row rests on, and Time is that line's timestamp. If you \
                    cannot fill the quote and the time, there is no action \
                    item and the row does not belong here.
                    """,
                format: NoteSection.list,
                itemFormat: "| Owner | Task | Due | Quoted line | Time |"),
            NoteSection(
                title: "Open questions",
                instruction: """
                    One bullet per question that was raised and not answered, \
                    and per thing somebody said they would go away and find \
                    out. Phrase each as the question itself, not as the topic \
                    it belongs to.
                    """,
                format: NoteSection.list),
        ])

    /// The second built-in exists to prove the first one is not special. A
    /// standup has no summary paragraph, no decisions and no owners column,
    /// and if the template mechanism could not express that it would not be
    /// a template mechanism.
    public static let dailyStandup = NoteTemplate(
        name: "Daily standup",
        sections: [
            NoteSection(
                title: "What shipped",
                instruction: """
                    One bullet per thing that is finished and out — merged, \
                    deployed, sent, signed off. If it is not finished it goes \
                    under In progress.
                    """,
                format: NoteSection.list),
            NoteSection(
                title: "In progress",
                instruction: """
                    One bullet per piece of work somebody is actively on, and \
                    where it has got to. Say what state it is in, not what it \
                    is.
                    """,
                format: NoteSection.list),
            NoteSection(
                title: "Blockers",
                instruction: """
                    One bullet per thing stopping work, naming who or what it \
                    is waiting on. If nobody said what would unblock it, say \
                    that rather than guessing at it.
                    """,
                format: NoteSection.list),
            NoteSection(
                title: "Next",
                instruction: """
                    One bullet per thing somebody said they would pick up \
                    before the next standup. Only what was said out loud; do \
                    not extrapolate from the blockers.
                    """,
                format: NoteSection.list),
        ])

    public static let builtIns: [NoteTemplate] = [standardMeeting, dailyStandup]

    /// Resolves a persisted template name.
    ///
    /// Falls back rather than failing, because the name is a string in
    /// UserDefaults and the ways it goes stale are all ordinary: a built-in
    /// renamed, a downgrade to a build that never had it, a hand-edited
    /// preference. None of those are worth turning into "notes unavailable"
    /// at the moment somebody presses the button after a two-hour call.
    /// Case-insensitive for the same reason LUT lookup is (§5.4).
    public static func named(_ name: String) -> NoteTemplate {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return builtIns.first {
            $0.name.caseInsensitiveCompare(wanted) == .orderedSame
        } ?? standardMeeting
    }
}
