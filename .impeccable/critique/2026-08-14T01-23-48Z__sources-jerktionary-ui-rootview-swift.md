---
target: the app
total_score: 24
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 4
timestamp: 2026-08-14T01-23-48Z
slug: sources-jerktionary-ui-rootview-swift
---
Method: dual-agent (A: /root/critique_design · B: /root/critique_detector)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 2/4 | Strong streaming/audio/error feedback, but shortcut failures, screenshot success, connection transitions, and meeting archival are not consistently visible. |
| 2 | Match System / Real World | 2/4 | “Backend,” “Swagger,” “LLM,” “API,” and “ризонинг” expose implementation vocabulary. |
| 3 | User Control and Freedom | 3/4 | Stop, retry, cancel, hide/expand, and destructive confirmations are solid; deletion has no undo. |
| 4 | Consistency and Standards | 3/4 | Native controls and interaction patterns are coherent; full and compact overlay opacity presets conflict. |
| 5 | Error Prevention | 2/4 | Destructive and attachment guards are good, but setup permits invalid configuration and completion without readiness checks. |
| 6 | Recognition Rather Than Recall | 2/4 | Core controls have labels/tooltips, but stealth behavior and global shortcuts rely on memory. |
| 7 | Flexibility and Efficiency | 3/4 | Strong shortcuts, compact mode, keyboard paging, paste/drop, and menu parity; history lacks search or bulk actions. |
| 8 | Aesthetic and Minimalist Design | 3/4 | Calm and coherent, but persistent meeting history plus nested Notes/Chat splits creates competing navigation and cramped three-column states. |
| 9 | Error Recovery | 2/4 | Backend and answer failures offer retry paths; settings validation and several recovery messages remain weak or technical. |
| 10 | Help and Documentation | 2/4 | Empty-state guidance and tooltips help, but there is no visible Help surface or permission/readiness guidance. |
| **Total** | | **24/40** | **Acceptable — significant improvements needed** |

## Design Specificity Verdict

**LLM assessment:** Functionally authored for Jerktionary; visually category-interchangeable. The live answer/transcript pairing, meeting context, answer pinning, stealth controls, and compact overlay are highly product-specific. The visual world—soft canvas, white rounded cards, lavender wash, SF Symbols, and diffuse shadows—is explicitly Journal-inspired and could serve almost any notes or AI utility unchanged. The strongest identity lives in the interaction design, especially the overlay, rather than composition, typography, or color.

**Deterministic scan:** The CLI returned `[]` (zero findings), but this is not meaningful clean coverage: the detector supports web extensions and skips `.swift`. Manual deterministic fallback checks found the four-step wizard has no visible progress, the final backend URL can complete without validation or readiness gating, and technical Backend/Swagger language leaks into recovery. The same checks confirmed strong reduced-motion handling, inactive-tab accessibility hiding, labeled icon controls, error announcements, and tab shortcuts.

**Visual evidence:** A native 1024×732 Jerktionary window launched successfully, but the app intentionally enables macOS screen-capture protection at startup, so the window could not be reliably captured. No browser or DOM overlay applies to a native SwiftUI surface, and no user-visible `[Human]` overlay exists.

## Overall Impression

A thoughtful native macOS utility with unusually mature operational states and a genuinely useful compact overlay. The biggest opportunity is to make the information architecture and visual hierarchy reflect the high-pressure live-call use case: today a generic productivity shell contains a specialized copilot.

## What’s Working

- **The compact overlay is the product’s strongest design.** It preserves an answer while it is being read, badges newly arrived answers, distinguishes silence from failure, and provides explicit hide/expand routes.
- **State coverage is mature.** Backend unavailable, component readiness, empty/listening/streaming/error states, retry actions, attachment capability checks, reduced motion/transparency, and accessibility announcements are handled deliberately.
- **The app behaves like a macOS app.** Native toolbar/menu patterns, Settings scene, split views, contextual menus, keyboard accelerators, text selection, and responsive `ViewThatFits` fallbacks provide a solid platform fit.

## Cognitive Load

**High: 4 of 8 checks fail.** Single focus, chunking, grouping, and progressive disclosure mostly pass. Visual hierarchy fails because the tinted meeting-context card remains prominent during listening; one-thing-at-a-time fails because live answers, transcript, context, terms, and toolbar state compete; minimal choices fails in the toolbar and full overlay; working memory fails because global shortcuts and hidden-overlay recovery must be remembered. Chat settings also present more than four simultaneous decisions: provider/model/reasoning information, model overrides, system prompt, and screenshot prompt.

## Emotional Journey

The first-run flow opens calmly but turns technical before establishing confidence: there is no progress, permission rehearsal, backend test, or reassuring readiness checklist. The peak—the arrival of a live answer—is supported by streaming feedback, readable answer typography, and an “Ответ готов” announcement, but the main composition does not make that peak dominant. The ending is weak: stopping silently archives a meeting without confirmation, summary, or a direct route to review it.

## Priority Issues

### [P1] The app creates unrelated nested navigation

**Why it matters:** The meeting sidebar persists across all tabs while Notes and Chat add their own list/editor split. Those destinations become three-column layouts, compressing the work area and implying that independent notes and chats belong to meeting history.

**Fix:** Make the leading rail contextual to the selected top-level section, or hide meeting history outside Session and expose it as a dedicated history destination.

**Suggested command:** `$impeccable distill`, then `$impeccable layout`.

### [P1] Live-session hierarchy does not match the speaking-under-pressure task

**Why it matters:** The answer a user must read aloud competes with a tinted editable context card and an equal-width, continuously moving transcript.

**Fix:** Make the live answer dominant; collapse context to a compact summary after listening begins; make transcript narrower, secondary, or revealable.

**Suggested command:** `$impeccable layout`.

### [P1] Setup allows false confidence

**Why it matters:** Four unlabeled steps provide no progress indicator, validation, permission state, backend test, or final readiness summary. Users can finish and immediately fail without knowing whether audio, screen recording, shortcuts, or service readiness is responsible.

**Fix:** Add visible progress, validate each step, explain/request permissions in context, test the service, and end with an audio/source/readiness checklist.

**Suggested command:** `$impeccable onboard`, then `$impeccable harden`.

### [P1] Critical stealth and shortcut actions rely on recall and silent outcomes

**Why it matters:** Hidden-overlay recovery depends on remembering Ctrl+Shift+O, silent screenshots do not distinguish discreet success from failure, and global hotkey conflicts are not user-visible.

**Fix:** Expose every accelerator in menus, add a discreet destination badge and accessibility announcement after screenshot capture, surface shortcut conflicts, and phrase protection controls as current state plus action.

**Suggested command:** `$impeccable clarify`, then `$impeccable harden`.

### [P2] Technical copy obscures an approachable product

**Why it matters:** “Backend,” “Swagger,” provider/model details, and “ризонинг” make first-time users translate architecture before ordinary setup and recovery.

**Fix:** Lead with task language such as “Сервис ответов” and “Проверить подключение”; move raw URLs, component details, model overrides, and Swagger under Advanced diagnostics.

**Suggested command:** `$impeccable clarify`, then `$impeccable distill`.

## Persona Red Flags

**Alex (Power User):** Cmd-1/2/3 are discoverable as menu shortcuts, but the four global accelerators are not. Meeting history has no search, keyboard-oriented selection, or bulk export/delete. Bare-arrow answer paging is fast but globally monitored and may surprise users outside an obvious focused pager.

**Jordan (First-Timer):** Backend, Swagger, and “ризонинг” appear before a plain-language mental model. Setup has no “step 2 of 4,” validation, permission explanation, or connection confirmation. Empty states say “Нажмите ✎” instead of naming the action, and the persistent meeting rail makes Notes and Chat look like meeting subsections.

**Sam (Accessibility-Dependent):** Semantic controls, explicit labels, reduced-motion/transparency handling, native text views, and announcements are strong. However, the audio level meter has no accessibility label/value; connection changes and meeting archival are not announced; tiny tertiary captions and low-opacity surfaces need live contrast verification; tooltip-only explanations do not help users who neither hover nor use VoiceOver.

## Minor Observations

- “Последний вопрос” is ambiguous between “latest” and “final”; “самый новый” is clearer.
- Sidebar history has no selected/current state or search and becomes a large blank rail when empty.
- Full and compact opacity controls offer inconsistent presets.
- Lavender mostly behaves as generic tint rather than encoding listening, answer readiness, or knowledge relationships.
- Stop-listening archives silently; notes rely on a small modified timestamp instead of an explicit saved state.
- Backend component names may leak internal identifiers directly into the recovery screen.

## Questions to Consider

- Is Jerktionary primarily a covert live-call copilot or a general notes/chat workspace? The current three equal top-level tabs avoid making that product choice.
- Once listening begins, should anything besides the answer remain visually dominant?
- Before the app hides itself from capture, which reassurance matters most: chosen audio source, permissions, service readiness, shortcut availability, or all four?
- Is the Journal-derived lavender-card aesthetic intentional brand territory, or a temporary shell around a more distinctive interaction model?
- At the end of a meeting, should the user get quiet confirmation or a review-and-act summary?
