// DiagnosticsPane.swift
// PRISM
//
// What happened this session (§5.17). The latency meter answers "what is
// this costing me right now"; this pane answers "why did my effects turn
// off", which is a question nobody asks until several minutes after the
// warning row has moved on.
//
// Everything shown here is held in memory and dies with the process. The
// Export button writes a file because the user pressed Export, and that is
// the only way anything here reaches disk.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var clock = SessionClock.shared

    var body: some View {
        Form {
            Section("This session") {
                LabeledContent("Running for",
                               value: SessionLog.duration(from: state.sessionLog.startedAt,
                                                          to: clock.now))
                LabeledContent("Dropped frames",
                               value: "\(state.sessionLog.droppedFrames)")
                LabeledContent("Added latency",
                               value: String(format: "%.1f ms now · %.1f ms peak",
                                             state.latency.totalAddedMs,
                                             state.sessionLog.peakAddedMs))
                Text("§3.4: a frame is never dropped to protect an effect — when the chain runs long, the effect goes, not the frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("GPU cost per effect") {
                if measuredStages.isEmpty {
                    Text("Nothing measured yet — the pipeline reports a cost only for effects that have actually run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(measuredStages, id: \.self) { id in
                        LabeledContent(id.displayName,
                                       value: String(format: "%.2f ms now · %.2f ms peak",
                                                     state.latency.stages[id] ?? 0,
                                                     state.sessionLog.peakStageMs[id] ?? 0))
                            .font(.body.monospacedDigit())
                    }
                }
            }
            Section("History") {
                if state.sessionLog.events.isEmpty {
                    Text("Nothing to report. Auto-disabled effects, device changes, dropped frames and anything that changed what clients could see land here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.sessionLog.events.reversed()) { event in
                        EventRow(event: event)
                    }
                }
            }
            Section {
                HStack(spacing: Metrics.itemGap) {
                    Button("Export…") { export() }
                        .disabled(state.sessionLog.events.isEmpty)
                    Button("Clear") { state.sessionLog.clear() }
                        .disabled(state.sessionLog.events.isEmpty)
                    Spacer()
                }
                Text("Kept in memory only, never sent anywhere, and gone when PRISM quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
    }

    /// Only stages with a number worth reading: the full list would be
    /// thirteen rows of 0.00 ms for effects the user never turned on.
    private var measuredStages: [StageID] {
        StageID.allCases.filter {
            (state.latency.stages[$0] ?? 0) > 0
                || (state.sessionLog.peakStageMs[$0] ?? 0) > 0
        }
    }

    private func export() {
        let text = state.sessionLog.exportText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "PRISM session.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct EventRow: View {
    let event: SessionEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.itemGap) {
            Image(systemName: event.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.text)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.kind.displayName): \(event.text)")
        .accessibilityValue(subtitle)
    }

    private var subtitle: String {
        let time = Self.formatter.string(from: event.first)
        guard event.count > 1 else { return time }
        return "\(time) · \(event.count) times, last at "
            + Self.formatter.string(from: event.last)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// Ticks once a second so the "Running for" row moves, and only while the
/// pane is on screen — a diagnostics view must not itself be something the
/// diagnostics have to explain.
@MainActor
private final class SessionClock: ObservableObject {
    static let shared = SessionClock()

    @Published private(set) var now = Date()
    private var timer: Timer?
    private var viewers = 0

    func start() {
        viewers += 1
        guard timer == nil else { return }
        now = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}
