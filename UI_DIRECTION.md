# Control-plane UI direction

## Status

This document is the design and implementation direction for the nixploy control
plane. New pages and workflows should follow it unless a deliberate product
change updates this document first.

The interface takes practical cues from the Sirkus Agio ERP operator surfaces,
but is shaped for nixploy's narrower job: understanding runtime state, deploying
immutable inputs, investigating failures, and making safe operational changes.
It is not a marketing site, a generic admin dashboard, or a second source of
application configuration.

## Product character

The UI should feel like a calm, compact operator console:

- **Utility before decoration.** Show current state, evidence, and the next useful
  action before explanatory or decorative content.
- **Task-focused rather than all-in-one.** Each primary route owns one operator
  job. Do not accumulate unrelated controls onto the overview.
- **Dense but readable.** Desktop can use available width for comparison and
  scanning; mobile keeps the same capabilities in a clear vertical flow.
- **Honest about state.** Loading, stale observations, failures, cancellation,
  partial effects, and unavailable runtime data must be visible.
- **Safe by construction.** Dangerous actions are visually distinct, explain
  their exact consequences, and require explicit confirmation.

## Information architecture

The primary navigation is intentionally small:

| Route | Operator job |
| --- | --- |
| `/` | Understand current runtime state and find the shortest path to action |
| `/workloads` | Inspect container identity, state, health, and bounded diagnostics |
| `/deployment-inputs` | Stage and review immutable Nix inputs |
| `/native-deployments` | Follow operation progress, investigate failures, and roll back |

Inputs and native deployments have stable detail URLs. New entities that need to
be linked, refreshed, or revisited should also receive stable URLs rather than
being available only through transient modal state.

`/compatibility` preserves the legacy workflow while it remains necessary, but
it is not part of primary navigation and must not shape new product design.

The overview is a status and routing page, not a compressed copy of every other
page. It may show concise counts, urgent failures, and common next actions, then
link to the owning workflow.

## Responsive application shell

### Mobile and narrow viewports

Below the Tailwind `lg` breakpoint:

- show a compact sticky header with the nixploy identity, current section, and
  one touch-sized hamburger button;
- open navigation as a full-viewport menu with large route targets;
- keep theme and operator controls in that menu rather than crowding the header;
- support close-button, route-selection, and Escape-key dismissal;
- allow the full-screen menu itself to scroll on short viewports;
- do **not** set persistent overflow classes or inline styles on `<body>` when
  opening the menu. LiveView navigation can replace the view before cleanup and
  leave the destination page scroll-locked.

Do not restore horizontally scrolling primary tabs. They hide destinations,
compete with browser chrome, and make the active section harder to understand.

### Laptop and desktop

At `lg` and wider:

- use the persistent 16rem left side navigation;
- keep the active destination obvious with `aria-current="page"` and strong
  contrast;
- place operator identity, theme, and session controls at the bottom of the
  sidebar;
- offset the content column from the fixed sidebar and constrain its readable
  maximum width;
- add density or side-by-side comparison where useful, but never add a desktop-
  only capability.

The shared shell lives in `lib/nixploy_web/components/layouts.ex`. Extend that
shell rather than creating page-specific navigation chrome.

## Page composition

A normal utility page should use this hierarchy:

1. A compact page header: contextual kicker, direct title, one-sentence purpose,
   and at most the primary page-level action.
2. A small status summary only when it helps the operator decide what to do.
3. One or more bounded panels organized around the route's task.
4. Stable links to deeper evidence or detail pages.
5. Explicit empty, loading, error, and stale states in the location where data
   would otherwise appear.

Prefer progressive disclosure. Keep common state and actions visible; put long
identifiers, command diagnostics, logs, audit evidence, and less-common controls
in focused detail areas without hiding failures.

Avoid:

- oversized hero sections or marketing copy;
- decorative charts without an operational decision attached;
- a grid of equally prominent cards when only one item needs attention;
- excessive shadows, gradients, glass effects, rounded pills, and accent colors;
- editable forms that duplicate flake-owned project configuration;
- hover-only controls or icon-only actions without accessible labels;
- modals as the only way to revisit operational evidence.

## Visual language

Use the existing Tailwind and daisyUI theme rather than introducing a parallel
component or token system.

- Neutral background and panel surfaces carry most of the interface.
- The primary orange accent marks context, links, focus, and selected actions; it
  is not general decoration.
- Semantic success, warning, and error colors communicate observed state.
- Sans-serif text carries labels and prose. Monospace is reserved for immutable
  identities, image references, hashes, runtime values, and compact uppercase
  kickers.
- Borders and spacing establish hierarchy before shadows do.
- Corners remain compact and controls remain practical rather than playful.

Reusable `np-*` primitives are defined in `assets/css/app.css`:

- `np-page-stack`, `np-page-header`, `np-kicker`, `np-page-title`, and
  `np-page-description` establish page hierarchy;
- `np-panel` and its header classes group a bounded workflow;
- `np-stat*` presents compact decision-relevant status;
- `np-action-*` presents clear next steps;
- `np-data-cell` and `np-field-label` present operational facts;
- `np-empty` provides a consistent empty state.

Extend these primitives when a pattern repeats. Keep one-off layout decisions in
HEEx utility classes instead of turning every arrangement into a component.

## Interaction and LiveView behavior

- Controls must have a minimum practical touch target of roughly 44px.
- Keyboard focus, semantic landmarks, a skip link, labels, and `aria-current`
  are part of the implementation, not later polish.
- Prefer LiveView navigation and `Phoenix.LiveView.JS` for small UI transitions.
  Add a custom JavaScript hook only when server-rendered components and JS
  commands cannot express the behavior safely.
- Never leave global browser state behind across LiveView navigation. Any global
  class, listener, or style needs navigation-safe cleanup and a regression test.
- Keep the page useful while commands are slow. Disable duplicate submissions,
  show progress near the initiating action, and retain durable operation links.
- Do not infer success from an optimistic animation. Render persisted state and
  independently observed runtime evidence.
- Keep logs and command output bounded. Long text and identifiers must wrap or
  scroll inside their own region without causing page-level horizontal overflow.
- Never render decrypted credentials or secret values.

## Implementation checklist

For every new or materially changed operator workflow:

- [ ] It has one clear operator job and belongs on the correct primary route.
- [ ] It works first at a narrow mobile viewport without horizontal page scroll.
- [ ] It remains fully usable with touch and keyboard, without hover.
- [ ] Laptop layout uses the shared sidebar and adds density only where useful.
- [ ] Primary state, failure, and next action are easy to find.
- [ ] Loading, empty, stale, unavailable, and error states are represented.
- [ ] Long identifiers, logs, and evidence cannot break the viewport.
- [ ] Destructive effects are explicit and confirmed.
- [ ] The route or detail state can be linked and revisited when appropriate.
- [ ] LiveView navigation cannot leave global scroll, focus, or overlay state
      behind.
- [ ] Stable selectors and tests cover navigation, critical actions, and the
      narrow-layout structure.
- [ ] No flake-owned configuration or decrypted secret has moved into the UI.

Review changes in a real narrow browser as well as desktop. Passing a responsive
CSS build alone is not evidence that an operator workflow is usable.
