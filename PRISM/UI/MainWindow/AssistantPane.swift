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
            // so it is written flatly and without hedging.
            Text("A detected question lights up the composer. It is never sent on its own. Nothing goes to the provider until you press the key — PRISM shows you what it thinks it heard so the chord has something ready, and that is the whole of it.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
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
            return "When you ask, what goes to the model is the last \(settings.clampedContextTurns) lines of transcript, whatever is under About you, and your question. Nothing else — not your audio, not your camera, not your screen. And with Ollama it stays on this Mac."
        case .anthropic, .openAICompatible:
            let destination = settings.provider == .anthropic
                ? "Claude" : "the endpoint you named above"
            return "When you ask, what goes to \(destination) is the last \(settings.clampedContextTurns) lines of transcript, whatever is under About you, and your question. Nothing else — not your audio, not your camera, not your screen. That request does leave this Mac, and nothing is sent until you ask for it."
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
}
