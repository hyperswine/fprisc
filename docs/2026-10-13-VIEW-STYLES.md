# View styles: no CSS text in an app

`std/view` generates a page's stylesheet from its view tree: only the classes the
tree uses are emitted. Until now an app that needed more than the utility table
appended a raw CSS string (`examples/pos1.fpr` had `cssApp`, about 30 lines, and
`std/livenotice` had `Notice.css`). This page records what replaced them.

## What std/view gained

- **Layout utilities** for "the page is the viewport and regions scroll inside it":
  `screen`, `flex-auto`, `flex-none`, `min-h-0`, `min-w-0`, `overflow-auto`,
  `overflow-hidden`, `content-start`, `justify-end`, `text-center`, `truncate`.
  `screen` also locks the body's scrolling (`body:has(.screen)`).
- **Breakpoint prefixes.** Any class, from the table or the app, takes `narrow:`
  (max-width 760px) or `wide:` (min-width 761px). Prefixed rules are emitted
  after every plain rule, inside their `@media`, so on their screen they win.
- **App styles as values.** `G.cssWith styles tree` takes a `List Style`:

  ```
  G.Style "pcard" [G.Width (G.Px 180), G.Height (G.Px 140)]
  G.Style "pcard-half" [G.Width (G.Less (G.Pct 50) (G.Px 4))]   # calc(50% - 4px)
  ```

  Lengths are `Px | Pct | Vh | Vw | Less`; declarations are the sizes (`Width`,
  `Height`, `Min*`, `Max*`, `Basis`) and `Prop name value` as the escape hatch.
  An app style is emitted only when the tree uses its name, like a utility, and
  replaces a utility of the same name. `cssFor tree` is `cssWith Nil tree`.
- **Empty live slots.** `.toast` and `.pre` still hide while their slot is empty;
  `show-empty` opts an element out, and `hide-empty` gives any element that
  behaviour.

## Result

pos1's stylesheet is `G.cssWith (Notice.styles + styles) sampleTree`, where
`styles` is eight sizes. The rest is utilities in the tree. `Notice.css` is now
`Notice.styles`.

Checked against the previous build in a browser at 1280x800 and 390x844: element
boxes, display, overflow and flex on all four tabs, and the cart's line rows,
are identical. `tests/viewcss.fpr` covers the generator; `tests/check_pos_reload.py`
and `tests/livenotice.fpr` pass.

## Open

- The property set is deliberately small. A colour or a position goes through
  `Prop`, which is a string again; typed constructors can be added when an app
  needs them more than once.
- Breakpoints are fixed at 760px. A configurable breakpoint would be a `Media`
  value beside `Style`.
