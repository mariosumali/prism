// ResourceGovernor.swift
// PRISM
//
// Who gets the memory, and what happens when there is not enough of it.
//
// §7 asks for resident memory under 250 MB. Every elastic allocation in the
// app was sized independently against that number, none of them knew about
// each other, and the sum had never been added up. It does not fit. Measured
// on an M-series Mac, one BGRA IOSurface slot costs 3.5 MB at 720p, 7.9 MB at
// 1080p and 31.7 MB at 4K, and FrameRing alone — half a second of raw camera,
// so its slot count follows the frame rate — measured 118.9 MB at 1080p30,
// 237.9 MB at 1080p60 and 474.8 MB at 4K30. A live session with the chain
// running measured 446 MB resident, 293 MB of it IOSurface.
//
// So the ring depth cannot be a constant. This picks it, and the still ring's
// depth beside it, from the negotiated format and what is left of the
// ceiling, in a fixed order that is the same every time: freeze's floor
// first, then the still ring the user actually asked for, then whatever is
// left widening the freeze window back toward half a second.
//
// The floor is the part that matters. Freeze promises the sharpest frame of
// the recent past (§5.2), and a ring too shallow to hold a choice turns that
// into "the frame at the moment you pressed it" — which is precisely what
// §5.2 says freeze is not. A blink closes the eyes for roughly 100–150 ms, so
// the window has to be longer than a blink for there to be anything better to
// pick; 200 ms is the shortest window that clears one, and six slots is the
// fewest that holds a choice at all once the slot being written and the slot
// still in flight are set aside. Hence: never fewer than six slots, and never
// less than 200 ms of wall time. Everything above that floor is negotiable.
//
// Those two floors pull against each other at high frame rates — 200 ms of
// 60 fps is twelve slots — so where the memory is not there, the ring records
// every second frame rather than shrinking its window. Six slots at stride
// two still span 200 ms and still hold a choice; they just hold a coarser
// one, which is a far cheaper loss than a window narrower than a blink.
//
// Nothing here allocates or touches the GPU. It is arithmetic on a format and
// a ceiling, which is what makes it testable — see ResourceGovernorTests.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// What the pipeline is being asked to hold, this format and this session.
public struct ResourceDemand: Equatable {
    public var format: VideoFormat
    /// §5.16 — the "sharpest frame" setting is armed, so the still ring wants
    /// output frames held. The only elastic demand a user switches on
    /// directly, which is why it outranks widening the freeze window.
    public var stillsWantSharpest: Bool
    /// §5.24 — a ScreenCaptureKit session is running. Not elastic and not
    /// negotiable: the framework holds its own queue of full-size surfaces
    /// and PRISM cannot shrink it below three, so it is a fixed cost that has
    /// to be taken off the top rather than something the plan can trade.
    public var screenSourceActive: Bool

    public init(format: VideoFormat, stillsWantSharpest: Bool = false,
                screenSourceActive: Bool = false) {
        self.format = format
        self.stillsWantSharpest = stillsWantSharpest
        self.screenSourceActive = screenSourceActive
    }
}

/// How much of what PRISM would like to hold it can actually afford. A rank,
/// not a severity: `minimum` is a working configuration, not a fault.
public enum ResourceTier: String, Equatable {
    case full        // the freeze window is the full half second
    case reduced     // shortened, still longer than the floor
    case minimum     // at the floor — freeze still picks, from less
    case exceeded    // even the floor does not fit inside the ceiling
}

/// The decision, and the sentences that explain it. Both surfaces read the
/// same plan, so neither can describe a policy the pipeline is not running.
public struct ResourcePlan: Equatable {
    public var format: VideoFormat
    /// FrameRing slots (§5.2).
    public var freezeDepth: Int
    /// Record one camera frame in this many. 1 is every frame; 2 halves the
    /// memory a given window costs at the price of a coarser choice within
    /// it, which is the right trade at 60 fps and pointless at 24.
    public var freezeStride: Int
    /// StillRing slots (§5.16); 0 means stills fall back to the last frame.
    public var stillDepth: Int
    /// Frames ScreenCaptureKit holds while a screen is being captured
    /// (§5.24); 0 when no screen session is running.
    public var screenDepth: Int
    public var plannedMB: Double
    public var ceilingMB: Double
    public var tier: ResourceTier
    /// What the still ring did with what it was given, when there is
    /// something to say. Silent when nobody asked for it.
    public var stillsSummary: String?

    public init(format: VideoFormat, freezeDepth: Int, freezeStride: Int = 1,
                stillDepth: Int, screenDepth: Int = 0,
                plannedMB: Double, ceilingMB: Double,
                tier: ResourceTier, stillsSummary: String? = nil) {
        self.format = format
        self.freezeDepth = freezeDepth
        self.freezeStride = freezeStride
        self.stillDepth = stillDepth
        self.screenDepth = screenDepth
        self.plannedMB = plannedMB
        self.ceilingMB = ceilingMB
        self.tier = tier
        self.stillsSummary = stillsSummary
    }

    /// How far back freeze can reach, in seconds.
    public var freezeSpanSeconds: Double {
        Double(freezeDepth * freezeStride) / Double(max(1, format.frameRate))
    }

    public var headroomMB: Double { ceilingMB - plannedMB }

    /// One sentence about the freeze window, for the diagnostics pane. The
    /// number is always in it: "reduced" without a figure is the kind of
    /// vagueness that makes people think something is broken.
    public var summary: String {
        let span = String(format: "%.2g s", freezeSpanSeconds)
        switch tier {
        case .full:
            return "Holding \(span) of recent camera — the full freeze window."
        case .reduced:
            return "Holding \(span) of recent camera to stay inside "
                + "\(Int(ceilingMB)) MB."
        case .minimum:
            return "Holding \(span) of recent camera — the shortest window "
                + "freeze can still pick a sharp frame from."
        case .exceeded:
            return "\(format.resolutionLabel) needs about \(Int(plannedMB.rounded())) MB, "
                + "more than the \(Int(ceilingMB)) MB PRISM aims to stay inside. "
                + "Freeze is holding the least it can."
        }
    }
}

public enum ResourceGovernor {

    // MARK: - The numbers, all of them measured

    /// §7's resident ceiling.
    public static let ceilingMB: Double = 250

    /// Everything that is not a pixel buffer. Measured: 36 MB peak with the
    /// whole chain built and no camera running, plus 33 MB for the three
    /// Vision models once they are resident (15.8 for segmentation, 11.1 for
    /// 76-point landmarks, 6.5 for hand pose), plus the capture session, the
    /// replay encoder and the preview view. Reserved at the live figure
    /// rather than the idle one: a budget that only holds until the user
    /// switches on background blur is not a budget.
    static let reservedMB: Double = 80

    /// Vision's staging buffers, itemised because the line used to read
    /// "three modalities × two 720p slots" and two of the four modalities are
    /// not at 720p: two BGRA slots each for segmentation and landmarks at
    /// 720p (7.0 MB each), two at 640×360 for presence (1.8 MB), two at
    /// 960×540 for hand pose (4.0 MB — fingers need more lines than a torso
    /// does, §5.31), and the three-deep mask pool, which is R8 rather than
    /// BGRA (2.6 MB). 22.4 MB against a reservation that was already 24, so
    /// the fourth modality fits inside the rounding the old sentence was
    /// carrying rather than costing the freeze window a slot. Fixed, because
    /// every request's input is capped regardless of the negotiated format.
    static let visionStagingMB: Double = 24

    /// Full-frame buffers the chain cannot run without: four in the output
    /// pool (two frames in flight, the retained last output, a crossfade
    /// endpoint), the two working intermediates it ping-pongs between, and
    /// the fit scratch a crossfade lands in. Not elastic — dropping any of
    /// them stops the pipeline rather than shrinking it.
    static let structuralFrames: Int = 7

    /// Style's own working-resolution textures (§5.29): the motion-effect
    /// history, and the scratch a stacked second pass lands in. Two frames,
    /// counted always rather than only while the stage is on.
    ///
    /// Counting them on demand was the obvious alternative and it is the
    /// wrong one: the freeze window would then change length when the user
    /// picked Underwater, and a freeze that reaches back four tenths of a
    /// second on Tuesday and three on Wednesday is worse to reason about
    /// than one that is permanently two slots shorter. This costs 1080p
    /// roughly three slots of ring, which is the honest price of the second
    /// pass and is written down here rather than discovered later.
    static let styleFrames: Int = 2

    /// Never fewer slots than this, whatever the arithmetic says. Two of any
    /// ring are unavailable at any instant — the one being written and the
    /// one whose command buffer has not landed — so six is the fewest that
    /// leaves freeze an actual choice.
    public static let minimumFreezeDepth = 6
    /// …and never less wall time than this. A blink closes the eyes for
    /// 100–150 ms; a window shorter than one has nothing sharper to offer.
    public static let minimumFreezeSeconds = 0.2
    /// §5.2's half second, and the most any of this is ever worth.
    public static let preferredFreezeSeconds = 0.5
    /// FrameRing's slot ceiling — half a second at 128 fps, far above §3.2.
    public static let maximumFreezeDepth = 64

    // MARK: - The policy

    /// Slots that hold the full §5.2 window at this format, every frame.
    public static func preferredDepth(for format: VideoFormat) -> Int {
        let byTime = Int((Double(max(1, format.frameRate)) * preferredFreezeSeconds).rounded(.up))
        return min(maximumFreezeDepth, max(minimumFreezeDepth, byTime))
    }

    /// Record one camera frame in this many, so `depth` slots still span the
    /// minimum window. At 30 fps and below this is always 1; at 60 it is what
    /// lets six slots cover 200 ms instead of 100, for half the memory a
    /// twelve-slot ring would cost. A coarser choice inside the window is a
    /// far smaller loss than a window narrower than a blink.
    public static func stride(depth: Int, frameRate: Int) -> Int {
        let wanted = minimumFreezeSeconds * Double(max(1, frameRate)) / Double(max(1, depth))
        return max(1, Int(wanted.rounded(.up)))
    }

    /// One full frame at this format, in MB. BGRA, so four bytes a pixel and
    /// no chroma subsampling to argue about.
    public static func frameMB(for format: VideoFormat) -> Double {
        Double(format.width * format.height * 4) / (1024 * 1024)
    }

    /// The plan. Deterministic: the same demand always produces the same
    /// answer, because a memory policy that depends on when you asked is one
    /// nobody can reason about after the fact.
    public static func plan(for demand: ResourceDemand) -> ResourcePlan {
        let format = demand.format
        let frame = frameMB(for: format)
        // ScreenCaptureKit's queue joins the structural frames rather than
        // the elastic ones: PRISM cannot make it smaller, so pretending it is
        // negotiable would only mean the freeze window is planned against
        // memory that is already spent.
        let screenDepth = demand.screenSourceActive ? ScreenCapture.queueDepth : 0
        let fixed = reservedMB + visionStagingMB
            + Double(structuralFrames + styleFrames + screenDepth) * frame

        let floor = minimumFreezeDepth
        let preferred = preferredDepth(for: format)

        // Freeze's floor is taken before anything is weighed, including
        // against the ceiling: a freeze that cannot pick is a broken feature,
        // and the honest response to not affording it is to say so.
        var remaining = ceilingMB - fixed - Double(floor) * frame
        var freezeDepth = floor

        // Then the still ring, because it is the one elastic demand a user
        // switched on deliberately (§5.16). It takes as many slots as fit,
        // down to a floor of its own; below that it is not worth the memory
        // and stills fall back to the last frame, which they already do.
        var stillDepth = 0
        if demand.stillsWantSharpest, frame > 0 {
            let affordable = Int(max(0, remaining) / frame)
            if affordable >= StillRing.minimumDepth {
                stillDepth = min(StillRing.maximumDepth, affordable)
                remaining -= Double(stillDepth) * frame
            }
        }

        // Whatever is left widens the freeze window back toward half a second.
        if frame > 0 {
            let extra = Int(max(0, remaining) / frame)
            freezeDepth = min(preferred, freezeDepth + extra)
            remaining -= Double(freezeDepth - floor) * frame
        }

        let planned = fixed + Double(freezeDepth + stillDepth) * frame
        let tier: ResourceTier
        if planned > ceilingMB {
            tier = .exceeded
        } else if freezeDepth >= preferred {
            tier = .full
        } else if freezeDepth > floor {
            tier = .reduced
        } else {
            tier = .minimum
        }

        return ResourcePlan(format: format,
                            freezeDepth: freezeDepth,
                            freezeStride: stride(depth: freezeDepth,
                                                 frameRate: format.frameRate),
                            stillDepth: stillDepth,
                            screenDepth: screenDepth,
                            plannedMB: planned,
                            ceilingMB: ceilingMB,
                            tier: tier,
                            stillsSummary: stillsSummary(demand: demand,
                                                         depth: stillDepth,
                                                         format: format))
    }

    private static func stillsSummary(demand: ResourceDemand, depth: Int,
                                      format: VideoFormat) -> String? {
        guard demand.stillsWantSharpest else { return nil }
        guard depth > 0 else {
            return "Stills take the last frame rather than the sharpest of the "
                + "last moment — holding finished \(format.resolutionLabel) frames "
                + "would not fit."
        }
        let span = Double(depth) / Double(max(1, format.frameRate))
        return String(format: "Stills pick the sharpest of the last %.2g s.", span)
    }
}
