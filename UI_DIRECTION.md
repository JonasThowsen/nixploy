# Control-plane UI direction

## Purpose

This document defines the design and implementation direction for the OCaml
Bonsai control plane. The interface exists to help an operator deploy an
application, understand recent deployments, cancel active work, investigate
logs, and judge host and application health.

It is a functional operator console, not a consumer landing page, a marketing
surface, or a generic administration template.

## Product character

- **Legible:** State, labels, values, and actions are readable at a glance. Use
  typography, spacing, borders, and contrast before decorative effects.
- **Interactive:** Controls respond clearly, retain useful context, and expose
  progress and errors beside the action that caused them.
- **Compact:** Prefer useful information density over large headings, empty
  space, and promotional copy. Density must not reduce touch usability.
- **Honest:** Distinguish requested, running, succeeded, failed, cancelled,
  unavailable, and stale state. Show when runtime facts were observed.
- **Calm:** Reserve strong color and motion for state, focus, and consequential
  actions. Avoid visual noise during long-running operations.

## Operator workflow

The primary surface should answer these questions in order:

1. Are the host and applications healthy?
2. What is deployed and what happened recently?
3. Which commit will the next deployment use?
4. Is a deployment active, and can it be cancelled?
5. What do the application logs say?

Information architecture may evolve as the product grows, but navigation should
remain small and use operator language. Do not expose Nix store internals,
configuration digests, or container implementation details unless they directly
help explain observed state or a failure.

## Responsive behavior

Mobile and desktop provide the same information, evidence, and actions. Desktop
may increase density or place related information side by side; it must not add
capabilities that disappear on mobile.

### Mobile

- Design and review at a narrow viewport first.
- Use a single clear content column and place the current state and primary
  action near the top.
- Stack label/value pairs when a row would become cramped.
- Convert wide deployment and metrics tables into readable records rather than
  relying on page-level horizontal scrolling.
- Keep interactive targets at least approximately 44px and separate destructive
  actions from routine controls.
- Keep filters, log search, refresh, follow, and cancellation reachable without
  hover or precision pointing.
- Let logs and long identifiers scroll or wrap inside their own bounded region.
  They must never widen the page.

### Desktop

- Use available width for scanning deployments, comparing application resource
  use, and keeping controls near their result.
- Constrain prose and error text to readable measures even when data panels are
  wide.
- Prefer aligned rows and columns when they improve comparison, but preserve the
  same reading order as mobile.
- Do not turn available space into oversized headers, empty hero regions, or a
  grid of equally prominent cards.

## Visual language

The current industrial operator-console direction is appropriate: strong
typographic hierarchy, restrained neutral surfaces, compact borders, and a small
set of semantic state colors.

- Use the accent color for focus, links, selected state, and the primary action,
  not as general decoration.
- Use success, warning, failure, active, and cancelled colors consistently and
  never as the sole carrier of meaning.
- Reserve monospace for commits, timestamps, log content, measurements, and
  other machine-originated values.
- Keep corners, shadows, gradients, and animation restrained.
- Avoid glass effects, decorative charts, oversized status numerals, and
  marketing-style slogans.
- Prefer real data labels over unexplained icons. Icon-only controls require an
  accessible name and should be rare.

## Data presentation

### Deployments

Recent deployment state must be scannable without opening every item. Lead with
application, state, commit subject and short SHA, time, duration, and stage.
Failure text belongs with the failed item and may expand for detail. The full SHA
remains copyable without dominating the layout.

### Commit confirmation

Show the human-readable subject and short SHA first, with full SHA and commit
time available in the same confirmation surface. Make it unambiguous that this
is the exact commit the action will deploy. Confirmation and cancellation must
remain practical with touch and keyboard input.

### Logs

The log viewer is an investigation tool rather than a decorative terminal:

- search remains visible while reading results;
- match count and next/previous controls are explicit;
- matched text and the active match are distinguishable without color alone;
- follow and paused states are obvious;
- new output must not unexpectedly steal scroll position while paused;
- loading, empty, truncated, unavailable, and stale states are visible;
- long lines scroll within the viewer, never at page level.

### Metrics

Metrics should support comparison and diagnosis. Always pair percentages with
their useful capacity context, such as memory used and total memory. State when
the sample was observed and which deployment target supplied it. Never present
the control-plane machine as the application host unless it actually is the
configured target. Charts are justified only when a trend changes an operator
decision; the first implementation should favor clear current values.

## Interaction behavior

- Every action has visible hover, focus, active, disabled, pending, success, and
  error behavior where applicable.
- Keyboard focus order follows the visual reading order and remains visible.
- Use semantic headings, landmarks, buttons, labels, and live regions before
  adding custom ARIA behavior.
- Polling must not reset selection, search text, scroll position, or expanded
  details.
- Disable duplicate mutations while preserving the operation's progress.
- Cancellation requires a concise confirmation that names the active deployment
  and explains that cleanup may continue briefly.
- Never infer success from client state. Render persisted operation state and
  independently observed runtime facts.
- Avoid animation that delays access or obscures changing operational data.
- Never render decrypted credentials or secret values.

## Bonsai implementation

- Keep state close to the component that owns the interaction.
- Separate protocol/domain values from their presentation instead of encoding
  behavior in CSS class strings or display text.
- Extract a component when it has a coherent interaction or is genuinely reused,
  not merely to shorten a file.
- Preserve user state across RPC polling and make stale responses explicit.
- Model loading, successful, failed, and disconnected RPC states deliberately.
- Keep formatting of commits, times, durations, byte values, and percentages in
  focused, testable functions.
- Prefer CSS layout and semantic HTML over browser-side measurement or imperative
  DOM manipulation.

## Review checklist

For every materially changed workflow:

- [ ] It has one clear operator purpose.
- [ ] It works at a narrow mobile viewport without page-level horizontal scroll.
- [ ] It remains fully usable with touch and keyboard and without hover.
- [ ] Desktop adds useful density without adding exclusive capabilities.
- [ ] State, failure, stale data, and the next useful action are easy to find.
- [ ] Loading, empty, unavailable, disconnected, and error states are represented.
- [ ] Polling preserves local interaction state.
- [ ] Logs and long machine values stay within their bounded region.
- [ ] Focus indicators, labels, contrast, and semantic structure are accessible.
- [ ] Critical interactions and responsive behavior have focused tests.
- [ ] The packaged UI was exercised in a real narrow and desktop browser.

Passing a CSS build or resizing a desktop layout is not evidence that a mobile
operator workflow is complete.
