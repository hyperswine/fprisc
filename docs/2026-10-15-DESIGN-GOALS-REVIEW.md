# Design goals audit: review, and the view model it leaves open

Date: 2026-10-15. Kind: review and refactor plan. Reviews
[2026-10-15-DESIGN-GOALS-AUDIT.md](2026-10-15-DESIGN-GOALS-AUDIT.md) and
extends it where it stops: the shape the views should take. The audit's
counts were reproduced independently the same day (grep on the three apps:
no `measure`, no bounds, no refinement preconditions, `Live.field` only in
logbook) and agree.

## The audit holds

Its method is right (counts, and the decisive experiment: compile each app
with `profile base.` instead of `unsafe base.` and read the refusals), and
its two substantive findings are the ones that matter:

- **The safety line is off in every app**, and 36 std modules are not on the
  allow-list in `compiler/Safety.hs`. That second fact is the larger one:
  it means std grew past the review its own trust boundary assumes, so
  "a safe program is refused if it may not terminate" is a claim about the
  compiler, not about what people run. The audit's fix (review the 36, put
  them on the list or repair them, fix the apps' 1 / 7 / 20 refused
  functions, drop `unsafe base.`, add a check that a module cannot ship off
  the list) is the right first item and should be first for this reason:
  every later refactor (persistence, views) is then checked as it is
  written.
- **Persistence is hand-written three ways.** Agreed, and agreed that
  `Live.field` over an event journal (append, fold on start, cut a torn
  tail, seed when empty, over `std/kvlog`/`std/wire`) is the one mechanism
  to converge on. The file handle inside the model is the clearest sign of
  what the framework was meant to absorb.

Two smaller points to add to it:

- Goal 4's weakness (client fields all `String`, mirrored as a JSON string)
  and goal 1's view verbosity are the same problem seen twice: the
  application speaks the browser's model (strings, divs, flex) instead of
  its own. Fixing one without the other leaves the seam.
- The audit's item 4, "name shared styles and drop the duplicate class
  strings", is a correct first step and too small an end: naming a
  13-property utility list `cardStyle` still has the application know that
  a card is a div with display flex. The rest of this page is about that.

## Where the audit stops: the view model

A page root in pos1 today:

```
element "div" (G.Utilities [G.Base [G.Display G.Flex, G.Direction G.Column,
  G.Gap (G.Px 18), G.Padding (G.Px 18), G.Height (G.Vh 100), ...]]) kids
```

This is what the 2026-10-13 and 2026-10-14 pages set out to reach, and they
reached it: typed, local, no CSS text, defined precedence. But the model is
still CSS's. A column is "a div whose display is flex and whose direction is
column". The design-patterns page asks for the model first and the spelling
second; the spelling changed, the model did not.

### The target shape

Layout and appearance as the application's own abstractions, in the spirit
of Elm's `elm-ui` (layout first: columns, rows, spacing, fill), over the
typed declaration layer `std/view` already has (`Decl`, `Len`, variants),
which plays the part `elm-css` plays:

```
page model =
  vstack { stack | gap = 18, pad = 18, fill = Screen } [
    header model,
    hstack { stack | gap = 8, align = Center } [ search model, sortMenu model ],
    scroll [ itemList model ],
    footer model ].

header model =
  hstack { stack | justify = Between, pad = 12 } [
    text { label | size = Title, weight = Bold } model.title,
    button { button | kind = Primary } Settings "Settings" ].
```

- **Layout nodes**: `vstack`, `hstack`, `grid`, `scroll`, `layer` (overlay),
  `space` (filler). Each takes an attribute record and children.
- **Attribute records with defaults**, the FP-RISC way: `stack`, `label`,
  `button` are ordinary record values and a call overrides fields by record
  update, `{ stack | gap = 18 }`. No named-argument syntax, nothing
  optional-by-string.
- **Typed appearance**: a `Theme` (palette, type scale, radii) passed down
  or declared as an inherited scope, as the local-UI page requires; sizes
  from a scale (`Title`, `Body`, `Small`), colours by role (`Accent`,
  `Muted`, `Danger`). A pixel literal belongs in a theme, not in a page.
- **Variants** stay typed, `{ button | when = [Hover [Raise], Narrow [Compact]] }`,
  and lower to the existing `Hover`/`Narrow` utilities.
- **Inputs and events are nodes**: `field`, `button`, `toggle`, keyed
  `list`, carrying the message VALUE and its codec, so the `OnClick`/`OnSet`
  strings leave the applications as the class strings did. This is also
  where goal 4 is fixed: a `field` for an `Int` client field is typed end
  to end through the generated codec.
- **Lowering, not a second renderer.** Every node above becomes the
  `El`/`Utilities`/`Decl` tree `std/view` renders today; the stylesheet
  generator, the live diff, keys and the wire format are unchanged. A
  `std/ui` module (name open) owns the lowering. Apps never name a tag, a
  class or a CSS property, and the string escape hatch `Prop` is not
  reachable from `std/ui`.

Acceptance for an application: no `element "div"`, no `G.Utilities`, no
`Cls "..."`, no pixel literal outside a theme, and the page reads as its
layout.

## One plan, merging the audit's items with this

1. **Close the safety gap** (the audit's item 1), first, so everything
   below is compiled checked.
2. **`std/ui` over `std/view`** with the nodes above, lowered to the current
   tree; generator tests in the manner of `tests/viewcss.fpr`, and the
   view-styles page's method for equivalence: element boxes at two
   viewports compared against the previous build.
3. **todo, then logbook**, rewritten to `std/ui` and to `Live.field` for
   every durable field (the audit's item 2), with measures on their
   recursive functions and refinements on wire inputs; `profile base.` at
   the top. The replay and browser checks keep passing.
4. **inventory, then pos1**, one pane at a time, typing the client state as
   they go (the audit's item 3); the acceptance record's checks are the
   regression suite.
5. **Record what the rewrite taught**: the `std/ui` nodes that were
   missing, the measures that could not be written, what the refinement
   pass could not prove, which std modules the allow-list review changed.
   Those are the compiler's and the library's next items, and better ones
   than any guess made before the rewrite.

## What this does not change

The completion contract's rules stand: generated assets only, local typed
presentation, no selector strings, no raw CSS, native services with
budgets. `std/ui` is a layer above them, and each rewritten app passes the
same four-hart, browser and failure-path acceptance.

## Progress (2026-10-15)

Steps 1 and 2 are done ([2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md](2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md),
[2026-10-15-STD-UI.md](2026-10-15-STD-UI.md)); step 3's todo and logbook
are rewritten, and what they taught is on the std/ui page. Next: inventory,
then pos1, pane by pane.
