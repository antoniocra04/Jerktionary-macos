---
target: the overlay
total_score: 19
max_score: 40
na_heuristics: 
p0_count: 3
p1_count: 2
timestamp: 2026-08-12T15-54-34Z
slug: sources-jerktionary-ui-overlayview-swift
---
Method: dual-agent (A: acee3e2a4fb61d088 · B: ae81f0474dcb04d6d)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 2 | 7pt dot bound to a Bool; overlay never reads websocketError, microphoneError, backendUnavailable or audioLevel |
| 2 | Match System / Real World | 3 | Natural Russian, but transcript empty state says «Нажмите "Слушать"» — a button absent from this mode |
| 3 | User Control and Freedom | 2 | A new question destroys the answer being read; no pager, previous answer unreachable |
| 4 | Consistency and Standards | 2 | journalCard's opaque fill at radius 16 nested in the 14pt glass card; reasoning Picker misses the compact controlSize the model Picker gets |
| 5 | Error Prevention | 2 | Opacity slider floor 0.25 drives panel.alphaValue — user can fade their own script to ~1.5:1 |
| 6 | Recognition Rather Than Recall | 2 | Three pane labels are the only recognition; all four hotkeys, prior answers and stealth state are recall |
| 7 | Flexibility and Efficiency | 2 | Global hotkeys are strong, but zero .keyboardShortcut in the repo; ← → gated to mainTab == .session, dead in the overlay |
| 8 | Aesthetic and Minimalist Design | 2 | Segmented picker is 43.7% of card width; Чат leads with two config dropdowns above the conversation |
| 9 | Error Recovery | 1 | Transport failures never render here; the one error that does is measured 2.09:1 |
| 10 | Help and Documentation | 1 | Three .help() tooltips, requiring a hover-dwell a user mid-sentence will never perform |
| **Total** | | **19/40** | **Poor — major UX work needed** |

## Design Specificity Verdict

**LLM assessment:** Expert plumbing, generic card. OverlayPanel.swift is authored work — every line removes a specific way the tool would blow the user's cover or yank their Space. The card inside is the default macOS floating-panel recipe: segmented Picker, two bare SF Symbols, ultraThinMaterial, radius 14, white 12% hairline. Strip the Russian and it could ship in a clipboard manager. Worse, the content is *borrowed*: AnswerCardView ends in journalCard(), an idiom built for a 1024×680 window, producing an opaque rectangle at radius 16 inside a translucent one at radius 14. Three tells that this surface was never designed for this moment: contentProtectionEnabled has a dedicated toggle in MainTopBar and is absent here — in the only mode used while sharing a screen; the hotkeys the main window teaches are invisible here; and nothing in the repo ever writes settings.overlayPane, so a persisted pane means an answer can stream into a pane the user cannot see.

**Deterministic scan:** Ran `detect.mjs --json Sources/Jerktionary/UI` → `[]`, exit 0. **This is zero coverage, not a pass.** SCANNABLE_EXTENSIONS in detector/node/file-system.mjs:25-29 has no `.swift`; all 15 Swift files were never opened. Control test with a planted HTML file returned 3 findings, so the tool works — it simply cannot see this target. All numbers below are bespoke measurement built for this run.

## Overall Impression

The window is the best-engineered thing in the project and the card inside it is the least-designed. Everything that makes this mode possible — non-activating panel, all Spaces, over full-screen, hidden from capture — is deliberate and correct. Everything the user actually looks at was inherited from a journaling app and never re-thought for someone reading aloud, under evaluation, while talking. The single biggest opportunity: the answer pane is the product, and right now it is the least-designed pane on the card.

## What's Working

- **The panel recipe.** hidesOnDeactivate = false (the app is always inactive during a call), collectionBehavior over another app's full-screen space, hasShadow = false so it doesn't read as "a window is open", sharingType propagated on show and on toggle. Six load-bearing decisions.
- **The `compact` flag is real adaptation, not scaling.** Measured branches: padding 0 vs 18, composer 26/72 vs 34/120, clear vs Theme.card, shadow suppressed, Enter hint hidden unless the backend is down.
- **The answer's information shape.** answer → points → example is exactly how you hand someone something to say. The content model is right; the container and typographic weighting betray it.

## Priority Issues

### [P0] A new question destroys the answer being read aloud
OverlayView.swift:89 renders `answeredQuestions.first` with no `.id()`, no pager. LiveAnswersView has both. Proven by execution, not inference: agent B clicked the real "Подробнее" button, then replaced the question list the way pushQuestion does. `@State deep` leaked into the new card, `answers.state(deep: true)` returned nil, and the card showed an indefinite "Готовлю ответ…" spinner **while the shallow answer was already in cache**. The action row that would let the user press "Короче" wasn't rendered at all.
**Fix:** render a pinned index, not `.first`; add `.id(question)`; badge a new answer instead of swapping; port the ← → pager with real `.keyboardShortcut`.
**Command:** /impeccable harden

### [P0] An answer arriving off-pane produces no signal at all
Exactly one writer of `settings.overlayPane` exists and it is the picker binding. The pane is @AppStorage-persisted, so last week's Чат is today's interview. A question is asked, the answer streams perfectly into a pane the user cannot see, and a segmented Picker cannot draw a badge.
**Fix:** replace the segmented Picker with three text buttons so a dot is drawable; auto-switch to .answer on the first question of a session only.
**Command:** /impeccable shape

### [P0] The overlay is structurally incapable of telling you it is broken
OverlayView never references websocketError, microphoneError, backendUnavailable, backendReady or audioLevel. RootView renders ErrorBanner and BackendUnavailableView for exactly these; the overlay renders the same serene hint(). A dropped socket, a stolen mic and "nobody has spoken yet" are pixel-identical.
**Fix:** drive the dot from audioLevel with idle/receiving/fault states; add a one-line error strip at .caption in .primary on red 15%.
**Command:** /impeccable harden

### [P1] The opacity control destroys legibility, and the default is already borderline
panel.alphaValue composites the whole card, text included. Measured: at the shipped default 0.9, dark secondary text sits at **4.52:1** — one hair over the line, and below it in light mode. At the 0.25 floor the slider permits, **body text is ~1.5:1 in every configuration**. No readout, no keyboard step, reachable only by hovering a ~10pt glyph.
**Fix:** apply opacity to the material layer only, keep alphaValue = 1, raise the floor to ~0.45, show the value.
**Command:** /impeccable audit

### [P1] The card breaks at its own documented minimum size, and every hit target is undersized
At 360×220 (WindowController.overlayMinSize) the hovered title bar needs ~370pt: the listening dot is pushed off the left edge and the collapse button is **clipped by 10pt**. The answer pane puts **44% of its content below the fold**; "Перегенерировать" wraps to three lines; the reasoning Picker holds 198pt = 55% of the width. Every interactive control in the title bar is under the 28pt comfortable minimum — the icon buttons are ~13pt squares. Nested padding (pane 8 + journalCard 18) eats 52pt of width. And the chat pane opens scrolled to the top: there is no initial scroll-to-bottom, only onChange.
**Fix:** let the picker compress, give icon buttons a 28pt frame, drop journalCard inside the overlay, scroll to bottom on appear.
**Command:** /impeccable layout

## Persona Red Flags

**Alex (power user):** Zero `.keyboardShortcut` in the entire repository — no ⌘1/2/3 for panes, nothing on Копировать or Перегенерировать. ← → are dead here (ArrowKeyMonitor gated to mainTab == .session) while the main window teaches "← → переключение". Ctrl+Shift+Space fails silently on both its early-return paths. Panel geometry isn't persisted (no setFrameAutosaveName) even though opacity and pane are — he re-places the card every launch.

**Sam (accessibility):** **Zero `.accessibilityLabel` in the whole codebase**; icon-only controls carry only `.help()`, which maps to AXHelp, not AXDescription. Status is color-only at 7pt, unlabeled, measured **1.93:1** dark / 1.59:1 light. 11 of 20 measured pairs fail 4.5:1 in dark, **14 of 20 in light**. No accessibilityReduceTransparency branch anywhere, and reduceMotion is honored in RootView and HeaderView but not in the overlay. Hover is the only path to the opacity control — unreachable by keyboard, VoiceOver or switch control.

**Marina, 29 — mid-interview on a shared screen (product's actual user):** She cannot verify stealth from the overlay; the eye/eye.slash toggle exists only in the window she deliberately hid. The only visible exit calls NSApp.activate(ignoringOtherApps: true) and slams a 1024×680 window forward — on a stealth tool, the last act of the session is maximal exposure. The card is pinned top-right while the laptop camera is top-center, making her gaze a repeatable tell. The `points` — the most speakable unit — are set in .callout, *smaller* than the prose they support.

## Minor Observations

- `AnswerCardView.latest` is a dead parameter, never read; the overlay passes `latest: true` to nothing.
- Theme.shadowColor at 0.05 alpha is invisible on dark glass; every journalCard in the overlay pays compositing cost for nothing.
- The white 12% hairline is applied in both appearances; in light mode it measures 1.02:1 — the card has no discernible edge.
- Switching panes destroys ChatThreadView's `@State draft`, so unsent composer text is lost (static analysis; not render-verified).
- `copy()`'s 1.5s label change resizes the button, sliding "Перегенерировать" under the cursor.
- level = .screenSaver puts the card above the menu bar and system alerts — defensible, but it should be a documented, overridable choice.
- Agent A and B disagreed slightly on a few material-backed contrast pairs; B's resolver numbers are used above, and every material-backed row is an approximation since offscreen rendering cannot sample a real desktop.

## Questions to Consider

1. If the card's job is to be read aloud, why is it laid out like a document? What would it look like if the only interaction were "next line"?
2. If content protection is the promise the product rests on, why does its indicator live only in the window the user has hidden?
3. Is "Ответ / Чат / Транскрипт" an information architecture, or three features that already existed? What breaks if the overlay is *only* the answer, and the 43.7%-wide picker is deleted?
4. answeredQuestions keeps 8 and the main window ships a pager; the overlay shows one and destroys it. Why did the mode that lives inside the conversation get the worse model?
