# Layout and navigation defaults for MVU applications

Design investigation, 12 November 2026. Baselines are FP-RISC 5c24b339, Terra II 5253bb2 and Dungeon a17c941. This extends the [pure game interface](2026-11-12-GAME-MVU.md). The same controls should work for ordinary application screens.

## Allocate space by role

Offer Header, Toolbar, Body, Status, Menu and Dialog constructors over the existing scene2d measurement pass. A header takes a title, essential actions and secondary actions. Measure the controls with the actual font and scale. Reserve room for essential controls, move secondary actions into a reachable overflow menu, then allocate the remaining title width. If essential controls and a useful title cannot share one row, use a stacked layout. A scrollable body gets the space left after the bars have been measured. Use a full-screen sheet for a dialog that exceeds the available height, with dismissal reachable while its body scrolls.

Text roles determine defaults. Descriptions wrap, a single-line title can shorten with access to the full value, and quantities and action labels need an intact representation or a different layout. Clipping is appropriate for a scrolling viewport. Consumed text and the accessible full label are separate outputs of measurement. Define a minimum supported viewport for each presentation; below it switch presentation or report the unmet constraint. Fixed coordinates remain useful for a board or artwork.

## Give each interaction one owner

Represent navigation as a root screen and a stack of overlays with unique instance IDs. A modal declares its title, initial focus, return-focus target and dismissal policy. Supply a conventional close or cancel action by default. For a mandatory choice, require reachable named outcomes. Opening the same singleton overlay twice is idempotent. Closing an overlay names its instance and only pops it when it is still current. Restore focus to the opener when available, otherwise to a declared fallback.

View describes the active stack. For each physical activation route against one committed tree, from the topmost eligible scope; stop after consumption. Bind modal dismissal to a fresh press by default, ignoring key repeat. Pair pointer press and release with the originating target so a newly exposed button cannot receive the tail of the dismissing click. Drawing, hit testing and keyboard focus use the same clipped tree and stable control IDs. Hidden and modal-obscured controls cannot receive ordinary input. Global shortcuts that intentionally escape a modal must be explicitly declared.

## Evidence before rollout

Start with Terra II's Pause → Keys → Terminal sequence. Its model stores one back screen. Returning from Terminal to Keys leaves Keys as its own back destination. Exercise the full unwind to Pause and Play with individual Escape presses, a held key, and a stale close for an earlier overlay. Verify focus restoration and that gameplay receives no dismissing input. Use Dungeon's help screen as the smaller second consumer.

Exercise a header with a long title, long action labels, an unbroken token, increased font scale and the narrowest supported viewport. Ask the headless layout engine for allocated rectangles, text dispositions, active focus scope and hit targets. Assert that required controls remain reachable, shortening follows the declared policy, unrelated interactive siblings do not overlap, and each activation produces at most one accepted action. Follow with rendered checks for actual glyph and focus visibility. Types can enforce required roles, bounded dimensions and explicit dismissal policies; measured geometry and transition tests cover facts that depend on text, viewport, fonts and event history.
