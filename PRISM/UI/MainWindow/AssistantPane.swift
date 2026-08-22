// AssistantPane.swift
// PRISM
//
// The main window's Assistant pane (§5.33): who answers, and how the panel behaves.
//
// The pane is ordered by consequence rather than by how often a control gets
// touched. Opacity and the opening corner are the two things people fiddle
// with, and they are near the bottom; the provider is at the top, because it
// is the only control on this surface that decides whether anything the user
// says on a call leaves this Mac. A pane that leads with the switch teaches
// that turning the assistant on is the decision. It is not. Choosing where
// the words go is the decision, and the switch is a consequence of it — which
// is why the switch is disabled until a provider is picked, with the reason
// written underneath rather than left for the user to deduce.
//
// The rejected alternative was the familiar one: a single "Enable AI" toggle
// with a working default, and the endpoint tucked into an advanced sheet for
// the people who care. That is a better first run and a worse product. It
// makes the network the default and the local model the expert option, when
// §5.33's whole argument is the reverse — Ollama is a first-class choice
// here, and `Off` is the shipped default precisely so that nobody discovers
// after the fact that their meeting went somewhere. A decision this
// consequential does not get made by a default nobody read.
//
// The privacy block at the bottom is standing, not conditional (§8.4), and
// it stops short of a promise PRISM cannot keep. `sharingType = .none` takes
// the panel out of window-list capture, which is what Zoom, Teams and PRISM's
// own screen source use — that part is worth stating plainly. A capture path
// that composites the framebuffer instead can still see it, Apple offers no
// API to prevent that, and the pane says so in the same breath. The version
// that said "nobody can ever see this" would be the version that got somebody
// caught.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct AssistantPane: View {
    @EnvironmentObject var state: AppState

    /// Never seeded from storage, and cleared the moment it is saved. The
    /// key is in the Keychain; this is only the box you paste into.
    @State private var keyDraft = ""
    @State private var keySaveFailed = false

    /// What Ollama reports it has pulled. Fetched on demand rather than when
    /// the pane opens: a Mac without Ollama should not pay for the lookup
    /// every time somebody comes here to change the opacity.
    @State private var installedOllamaModels: [String] = []
    @State private var isFindingModels = false
    @State private var ollamaLookupFailed = false

    private var settings: AssistantSettings { state.studio.assistant }

    var body: some View {
        Form {
            providerSection
            panelSection
            liveInsightsSection
            aboutMeSection
            privacySection
        }
        .formStyle(.grouped)
    }

    // MARK: - Who answers

    private var providerSection: some View {
        Section("Who answers") {
            Picker("Answers come from", selection: providerBinding) {
                ForEach(LLMProviderKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .help("Where a question goes when you ask one")
            .accessibilityLabel("Assistant provider")

            switch settings.provider {
            case .none: offDetail
            case .anthropic: anthropicDetail
            case .ollama: ollamaDetail
            case .openAICompatible: compatibleDetail
            }
        }
    }

    @ViewBuilder
    private var offDetail: some View {
        Text("Off means off. Nothing leaves this Mac, and there is nowhere for a question to go, so nothing can be asked.")
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        Text("Transcription is separate and runs on this machine either way. Picking a provider here is what turns on written notes and answers — including the ones you never send, because a panel with no provider behind it has nothing to say.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Claude

    @ViewBuilder
    private var anthropicDetail: some View {
        HStack(spacing: Metrics.itemGap) {
            SecureField("API key", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .help("Paste a key from console.anthropic.com")
                .accessibilityLabel("Anthropic API key")
            Button("Save") { saveKey() }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Put this key in your login keychain")
            if state.hasAnthropicKey {
                Button("Remove") { removeKey() }
                    .help("Delete the saved key from your keychain")
                    .accessibilityLabel("Remove the saved API key")
            }
        }

        Text(keyStatus)
            .font(.caption)
            .foregroundStyle(keySaveFailed ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)

        // Said before anybody wonders why the box is empty on the way back
        // to this pane.
        Text("The key is kept in your login keychain, not in settings, and never in an exported preset. PRISM will not show it back to you — the box is blank because there is nothing safe to put in it, not because the key was lost. If you forget it, paste a new one.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Picker("Model", selection: modelBinding) {
            ForEach(LLMModelCatalog.anthropic) { entry in
                Text(entry.displayName).tag(entry.id)
            }
            if unknownAnthropicModel {
                Text(settings.anthropicModel).tag(settings.anthropicModel)
            }
        }
        .help("Which Claude model writes the answer")
        .accessibilityLabel("Claude model")

        Text(anthropicModelBlurb)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var keyStatus: String {
        if keySaveFailed {
            return "The keychain refused to store that. Nothing was saved."
        }
        return state.hasAnthropicKey
            ? "A key is saved."
            : "No key yet. Answers will fail until there is one."
    }

    private var unknownAnthropicModel: Bool {
        !LLMModelCatalog.anthropic.contains { $0.id == settings.anthropicModel }
    }

    private var anthropicModelBlurb: String {
        if let entry = LLMModelCatalog.anthropic.first(where: { $0.id == settings.anthropicModel }) {
            return entry.detail
        }
        return "A model identifier PRISM does not recognise. It is sent exactly as written, which is the point — model names change faster than this app ships."
    }

    // MARK: Ollama

    @ViewBuilder
    private var ollamaDetail: some View {
        HStack(spacing: Metrics.itemGap) {
            TextField("Model", text: modelBinding)
                .textFieldStyle(.roundedBorder)
                .help("The name Ollama knows this model by, such as llama3.1:8b")
                .accessibilityLabel("Ollama model name")
            Button(isFindingModels ? "Looking…" : "Find installed models") {
                findOllamaModels()
            }
            .disabled(isFindingModels)
            .help("Ask Ollama on this Mac which models it has pulled")
        }

        // Appears only once there is a list, and writes into the same field
        // above rather than storing a second answer to the same question
        // (§8.7): one value, two ways to reach it.
        if !installedOllamaModels.isEmpty {
            Picker("Installed", selection: modelBinding) {
                ForEach(installedOllamaModels, id: \.self) { name in
                    Text(name).tag(name)
                }
                if !installedOllamaModels.contains(settings.ollamaModel) {
                    Text(settings.ollamaModel.isEmpty ? "Not chosen" : settings.ollamaModel)
                        .tag(settings.ollamaModel)
                }
            }
            .help("Picking one fills the box above")
            .accessibilityLabel("Models Ollama has pulled")
        }

        if ollamaLookupFailed {
            Text("Ollama did not answer on this Mac. Start it, or type the model name yourself — PRISM sends whatever is in the box.")
                .font(.caption)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("Ollama runs on this Mac, so nothing you ask leaves it — not the question, and not the transcript that goes with it. The trade is honest: the answer is only as good as the model you have pulled, and a small one on a laptop can be slower than the network would have been.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Another endpoint

    @ViewBuilder
    private var compatibleDetail: some View {
        TextField("Base URL", text: baseURLBinding)
            .textFieldStyle(.roundedBorder)
            .help("Where the OpenAI-compatible API lives, such as http://127.0.0.1:8080/v1")
            .accessibilityLabel("Endpoint base URL")
        TextField("Model", text: modelBinding)
            .textFieldStyle(.roundedBorder)
            .help("The model identifier that endpoint expects")
            .accessibilityLabel("Endpoint model name")
        Text("For llama.cpp's server, LM Studio, vLLM, or your company's own endpoint. PRISM connects to the address you type here and nowhere else — it does not go looking for a service, and it never falls back to another provider when this one is unreachable. A question that cannot be delivered fails in front of you.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The panel

    private var panelSection: some View {
        Section("The panel") {
            Toggle("Show the assistant", isOn: enabledBinding)
                .disabled(settings.provider == .none)
                .help("Float the answer panel over your own screen\(state.shortcutSuffix(.ask))")
            if settings.provider == .none {
                Text("Pick a provider above and the switch has somewhere to send a question.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrismSliderRow(label: "Opacity", value: opacityBinding,
                           range: 0.35...1, defaultValue: 0.9,
                           fractionDigits: 2)

            Picker("Opens at", selection: anchorBinding) {
                ForEach(AssistantAnchor.allCases, id: \.self) { anchor in
                    Text(anchor.displayName).tag(anchor)
                }
            }
            .pickerStyle(.segmented)
            .help("Which corner the panel appears in the first time")
            .accessibilityLabel("Opening corner")
            Text("Only where it opens. Drag it wherever you want it and it stays there, including on the next call — this setting is the starting point, not a leash.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PrismSliderRow(label: "Context", value: contextTurnsBinding,
                           range: 4...30, defaultValue: 14,
                           fractionDigits: 0, unit: " lines", snap: 1)
            Text("How much of the conversation goes along with a question you type. More is not better: a long history dilutes a direct answer rather than sharpening it, and every line costs time before the first word comes back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Light up when I'm asked something", isOn: highlightsBinding)
                .help("Mark the composer when the other side appears to have asked a question")
                .accessibilityLabel("Highlight detected questions")
            // The sentence that decides whether this feature is trustworthy,
            // so it is written flatly and without hedging — and it changes
            // when §5.34 is on, because then it would be false.
            Text(detectionCaption)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detectionCaption: String {
        if settings.liveInsights {
            return "A detected question lights up the composer — and while live insights is on, it is also one of the two things that prompt a request, so an answer card may follow it. Turn live insights off below and nothing goes to the provider until you press the key."
        }
        return "A detected question lights up the composer. It is never sent on its own. Nothing goes to the provider until you press the key — PRISM shows you what it thinks it heard so the chord has something ready, and that is the whole of it."
    }

    // MARK: - Live insights (§5.34)

    /// The one section in this pane about something that sends on its own,
    /// which is why it says how often in numbers rather than adverbs, and
    /// why the switch is disabled until there is somewhere to send to.
    private var liveInsightsSection: some View {
        Section("Live insights") {
            Toggle("Show me things as the call goes on", isOn: liveInsightsBinding)
                .disabled(settings.provider == .none)
                .help("Cards appear on the panel without you asking\(state.shortcutSuffix(.insights))")
                .accessibilityLabel("Live insights")
            Text(liveInsightsBlurb)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Pace", selection: insightPaceBinding) {
                ForEach(InsightPace.allCases, id: \.self) { pace in
                    Text(pace.displayName).tag(pace)
                }
            }
            .pickerStyle(.segmented)
            .help("How often PRISM looks at the conversation")
            .accessibilityLabel("Live insights pace")
            Text(settings.insightPace.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(InsightKind.allCases, id: \.self) { kind in
                Toggle(kind.displayName, isOn: insightKindBinding(kind))
                    .help(kind.rule.prefix(1).uppercased() + kind.rule.dropFirst())
                    .accessibilityLabel(kind.displayName)
            }
            if settings.insightKinds.isEmpty {
                Text("Every kind is off, so nothing is asked for. That is the same as the switch being off.")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InsightCadenceText(session: state.insights, pace: settings.insightPace)
        }
    }

    /// Standing, never conditional (§8.4): this is the sentence that tells
    /// the user PRISM will send without a key press, and it has to be
    /// readable before the switch is flipped, not after.
    private var liveInsightsBlurb: String {
        "While you are listening and the panel is up, PRISM sends the last \(settings.clampedContextTurns) lines to \(destinationName) on its own and puts up a card when there is something worth saying — the answer to what you were just asked, a term that went past, a commitment somebody made. It is told that nothing is the usual answer, and most of the time it shows nothing. Turning this on starts listening if you were not already. This is the one thing in PRISM that sends without you pressing a key, which is why it has its own switch."
    }

    private var destinationName: String {
        switch settings.provider {
        case .none: return "your provider"
        case .anthropic: return "Claude"
        case .ollama: return "Ollama on this Mac"
        case .openAICompatible: return "the endpoint you named"
        }
    }

    // MARK: - About you

    private var aboutMeSection: some View {
        Section("About you") {
            TextEditor(text: aboutMeBinding)
                .font(.body)
                .frame(minHeight: 100)
                .help("Who you are and what you work on, sent with every answer")
                .accessibilityLabel("About you")
            Text("This goes with every answer. It is the difference between a generic answer and a usable one — your role, what your company actually sells, the names of the products and people that come up. Three sentences is plenty.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It is stored in settings rather than the keychain, because it is not a secret. Do not put one here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Privacy (§8.4: standing, never conditional)

    private var privacySection: some View {
        Section {
            Text("Nobody on the call can see the panel. It is never drawn into the picture, and macOS keeps it out of a screen recording that goes window by window — which is what Zoom, Teams and PRISM's own screen source do.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(captureCaveat)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(whatIsSent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The narrow half of the guarantee, said out loud. `sharingType = .none`
    /// is a window-list promise; a framebuffer grab is not covered and Apple
    /// ships no way to cover it.
    private var captureCaveat: String {
        let chord = state.shortcutLabel(.ask)
        let key = chord.isEmpty ? "the ask shortcut" : chord
        return "Some apps grab the whole screen instead of a list of windows, and those will see it. Apple provides no way to stop that, so the reliable defence is keeping the panel off screen when you are not using it: the switch above puts it away, and \(key) brings it back the moment you want it. The ask key only ever asks — it will not make the panel vanish, because something you cannot see you dismissed is something you cannot get back."
    }

    /// The inventory. Short, complete, and phrased as a list of things rather
    /// than a reassurance, because a reassurance is not checkable.
    private var whatIsSent: String {
        switch settings.provider {
        case .none:
            return "Nothing leaves this Mac while the provider is Off. There is no request to describe."
        case .ollama:
            let timing = settings.liveInsights
                ? "When you ask, and automatically while Live insights is on,"
                : "When you ask,"
            return "\(timing) what goes to the model is the recent transcript, whatever is under About you, and the question or card request. Nothing else — not your audio, not your camera, not your screen. And with Ollama it stays on this Mac."
        case .anthropic, .openAICompatible:
            let destination = settings.provider == .anthropic
                ? "Claude" : "the endpoint you named above"
            let timing = settings.liveInsights
                ? "When you ask, and automatically while Live insights is on,"
                : "When you ask,"
            return "\(timing) what goes to \(destination) is the recent transcript, whatever is under About you, and the question or card request. Nothing else — not your audio, not your camera, not your screen. Those requests do leave this Mac."
        }
    }

    // MARK: - Actions

    private func saveKey() {
        let ok = state.setAnthropicKey(keyDraft)
        keySaveFailed = !ok
        if ok { keyDraft = "" }
    }

    private func removeKey() {
        _ = state.setAnthropicKey("")
        keyDraft = ""
        keySaveFailed = false
    }

    private func findOllamaModels() {
        isFindingModels = true
        ollamaLookupFailed = false
        Task { @MainActor in
            let found = (try? await OllamaProvider.installedModels()) ?? []
            installedOllamaModels = found
            ollamaLookupFailed = found.isEmpty
            isFindingModels = false
        }
    }

    // MARK: - Bindings

    private var providerBinding: Binding<LLMProviderKind> {
        Binding(
            get: { state.studio.assistant.provider },
            set: { state.setAssistantProvider($0) })
    }

    /// One binding for all three providers: `setAssistantModel` writes to
    /// whichever one is selected, and only the matching field is on screen.
    private var modelBinding: Binding<String> {
        Binding(
            get: {
                switch state.studio.assistant.provider {
                case .anthropic: return state.studio.assistant.anthropicModel
                case .ollama: return state.studio.assistant.ollamaModel
                case .openAICompatible: return state.studio.assistant.compatibleModel
                case .none: return ""
                }
            },
            set: { state.setAssistantModel($0) })
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { state.studio.assistant.compatibleBaseURL },
            set: { state.setAssistantBaseURL($0) })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.studio.assistant.isEnabled },
            set: { state.setAssistantEnabled($0) })
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { state.studio.assistant.clampedOpacity },
            set: { state.setAssistantOpacity($0) })
    }

    private var anchorBinding: Binding<AssistantAnchor> {
        Binding(
            get: { state.studio.assistant.anchor },
            set: { state.setAssistantAnchor($0) })
    }

    private var contextTurnsBinding: Binding<Double> {
        Binding(
            get: { Double(state.studio.assistant.clampedContextTurns) },
            set: { state.setAssistantContextTurns(Int($0.rounded())) })
    }

    private var highlightsBinding: Binding<Bool> {
        Binding(
            get: { state.studio.assistant.highlightsQuestions },
            set: { state.setAssistantHighlightsQuestions($0) })
    }

    private var aboutMeBinding: Binding<String> {
        Binding(
            get: { state.studio.assistant.aboutMe },
            set: { state.setAssistantAboutMe($0) })
    }

    private var liveInsightsBinding: Binding<Bool> {
        Binding(
            get: { state.studio.assistant.liveInsights },
            set: { state.setLiveInsights($0) })
    }

    private var insightPaceBinding: Binding<InsightPace> {
        Binding(
            get: { state.studio.assistant.insightPace },
            set: { state.setInsightPace($0) })
    }

    private func insightKindBinding(_ kind: InsightKind) -> Binding<Bool> {
        Binding(
            get: { state.studio.assistant.insightKinds.contains(kind) },
            set: { state.setInsightKind(kind, enabled: $0) })
    }
}

/// A live, factual account of automatic model traffic. The configured pace
/// explains the ceiling; the count says what this meeting has actually used.
private struct InsightCadenceText: View {
    @ObservedObject var session: InsightSession
    let pace: InsightPace

    var body: some View {
        Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Live insights request count")
            .accessibilityValue(summary)
    }

    private var summary: String {
        let count = session.requestCount
        let used = count == 1 ? "1 request this meeting" : "\(count) requests this meeting"
        let limit = InsightPolicy.forPace(pace).requestsPerWindow
        return "\(used). This pace allows at most \(limit) requests in any ten minutes."
    }
}
