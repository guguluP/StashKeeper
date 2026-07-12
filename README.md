# StashKeeper

A SwiftUI app (iOS + macOS) for cataloging where you've stored things,
using on-device Apple Intelligence (Foundation Models) to auto-identify
items from photos, track expiry, suggest recipes from what's on hand, and
answer questions about your stash through an in-app chat assistant.

## Status

This is an actively developed Xcode project — it builds and runs on both
the iOS and macOS targets. Development has mostly happened by exchanging
zips with Claude and applying fixes based on real Xcode build output, so
treat this repo as the current working state rather than a finished 1.0.

## Requirements

- Xcode 26+ (Foundation Models, `@Generable`/guided generation, and the
  Liquid Glass UI APIs used throughout require the latest SDK)
- iOS 26+ / macOS 26+ deployment targets
- A physical Apple Intelligence-eligible device for full AI features to
  exercise the on-device model path (the Simulator can still run the app;
  AI features fall back to the zero-AI heuristic tier — see below — when
  Apple Intelligence isn't available, so nothing hard-crashes without it)

## What's implemented

### Core cataloging
- SwiftData models (`StashItem`, `StorageLocation`, `StreakRecord`) with
  computed expiry status, search text, formatted price, and notification
  bookkeeping, shared with the widget extension via an App Group container.
- Multi-item Vision pipeline: one photo or video can contain several
  distinct items, each detected as its own region, classified, and OCR'd
  independently.
- Barcode scanning with a three-tier product lookup: Open Food Facts →
  UPCitemdb → a local, self-learning Indian FMCG cache (seeded with common
  brands, and it remembers any barcode you manually confirm a name for, so
  repeat scans resolve instantly).
- Camera capture (multi-shot, in addition to the Photos picker) for adding
  items straight from the device camera.
- Price and nutrition extraction from packaging OCR.
- Milestones/streaks with a full Apple Fitness-style award unlock
  (tiered rings, Metal confetti burst, haptics).

### Apple Intelligence (Foundation Models)
Apple only exposes one model tier to third-party apps — the on-device
model via `SystemLanguageModel`. Within that constraint:
- Warm, persistent `LanguageModelSession`s per task (item analysis, search,
  chat, receipt parsing) rather than a fresh session per call.
- Tool calling — sessions can call back into the app mid-reasoning
  (`InventoryLookupTool`, `HealthContextTool`) to check real inventory or
  today's HealthKit activity instead of reasoning over a static snapshot.
- Private Cloud Compute fallback for larger/harder batches, with graceful
  degradation to a documented, explainable **zero-AI heuristic tier**
  (`HeuristicItemNamer`, `HeuristicAssistantEngine`, `ReceiptHeuristicParser`)
  on devices that can't run Apple Intelligence at all — the app stays
  useful, just with lower-confidence naming/categorization and simpler,
  rule-based chat answers instead of open-ended conversation.

### Receipt scanning
Photograph a supermarket bill, and Foundation Models extracts individual
line items (name, quantity, price, category guess) from the OCR text.
Each extracted item becomes a checklist row; tapping one launches the
normal photo-capture flow (pre-filled with the receipt's name/price as a
soft hint, not an override) so the item still gets properly cataloged from
an actual photo rather than receipt text alone.

### Stash Assistant (chat)
An in-app chat surface (prompt chip on Dashboard → full chat screen) that
can answer inventory questions, check what's expiring, and suggest recipes
using live tool calls against your actual data — with the same heuristic
fallback for devices without Apple Intelligence.

### Health integration
`HealthKitService` (iOS only) surfaces today's activity summary to the
recipe suggestion engine and the chat assistant, so suggestions can factor
in how active the day's been. Nutrition logging to Health is manual-only
from Item Detail — auto-write on save was deliberately left out, since
HealthKit models consumption, not pantry stock.

### Platform notes
- macOS gets a `MenuBarExtra` summary view and a native window with
  `NavigationSplitView`/sidebar commands.
- Widget Extension (`StashKeeperWidgets/`) shares the same SwiftData store
  via App Group for a live expiring-items timeline.
- Live Activities for scan-in-progress status.
- 7 App Intents/Siri shortcuts.

## Project structure

```
StashKeeper/
├── StashKeeper.xcodeproj/       Xcode project (Xcode 16+ file-system
│                                synchronized groups — new files in the
│                                folders below are picked up automatically,
│                                no manual project file edits needed)
├── StashKeeper/
│   ├── Models/                  SwiftData models + Foundation Models
│   │                            @Generable structs
│   ├── Services/                Vision, AFM, barcode/receipt, HealthKit,
│   │                            notifications, heuristic fallbacks
│   ├── Views/                   SwiftUI views, organized by flow
│   │   ├── AddItemFlow/         Capture → analyze → review pipeline,
│   │   │                        camera, receipt scanning
│   │   ├── Assistant/           Chat UI
│   │   ├── Dashboard/           Main list/stats/milestones screens
│   │   └── Shared/              Reusable components, animation primitives
│   ├── Intents/                 App Intents / Siri shortcuts
│   ├── LiveActivity/            Scan-progress Live Activity
│   ├── Assets.xcassets/         App icon, accent color
│   └── AppIcon/                 Source layers for Icon Composer
└── StashKeeperWidgets/          Widget Extension target
```

## A few known areas worth double-checking on-device

- **Region proposal tuning**: `VisionAnalyzer`'s saliency-based region
  proposal is general-purpose, not household-object-specific. If
  multi-item detection feels too aggressive or too conservative, the knobs
  are `minObjectnessConfidence`, `minRegionAreaFraction`, and the merge
  threshold in `mergeOverlapping`.
- **Milestone thresholds**: tune per-tier counts in `MilestoneTier.threshold`
  to taste — currently a starting guess, not data-driven.
- **Price/nutrition accuracy**: both are AI-estimated from OCR + general
  knowledge, surfaced with confidence scores in the UI — treat them as
  estimates to spot-check, not lab-grade values.
- **Indian FMCG barcode cache** (`IndianFMCGBarcodeCache`) is seeded with
  a handful of major brands as a starting point, not an exhaustive
  database — it grows from real usage (`BarcodeLookupTelemetry` logs
  hit/miss patterns locally so gaps are visible over time).
