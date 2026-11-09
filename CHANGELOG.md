# Changelog

## 0.1.1

- Text in `MarkdownView`, `ReadingMode` and the `SourceMode` split preview can
  now be selected and copied
  ([alliswell#43](https://github.com/mahirozdin/alliswell/issues/43)). The
  whole document is one selection: a drag or select-all copies across
  paragraphs, headings, lists, quotes, tables and code, and the copy keeps the
  page's shape — a blank line between blocks, a newline between list items
  and table rows, a tab between table cells. Works with the mouse and the
  keyboard, and with a long-press and the selection toolbar on touch screens.
- Select-all copies the whole document, also when it is far taller than the
  screen: while text is selected the lazy list builds every block (it goes
  back to building lazily when the selection ends). Blocks folded under a
  collapsed heading are not shown and are not copied.
- A formula is copied as its TeX source (`$x$`, or a `$$` block) and an image
  as its alt text, instead of leaving a gap; each selects as one unit.
- Code blocks and the "cannot be drawn" fallback join that same selection
  instead of each being a separate one; the code block's copy button is
  unchanged, and its language label is no longer part of a copy. Used on
  their own, outside any selection area, `MdCodeBlock` and
  `MdUnsupportedBlock` are still selectable by themselves, as before.
- `MarkdownView(selectable: false)` turns selection off, code blocks included.
  The view adds its own `SelectionArea` only when there is no selection setup
  above it: a host that already wraps its screen in one is not nested, and a
  host that turned selection off with `SelectionContainer.disabled` keeps it
  off. The highlight follows the host's theme in light and dark.

## 0.1.0

First extraction, from [AllisWell](https://github.com/mahirozdin/alliswell)
(OPH-274 / ADR-0033), where every part of this package shipped and was tested
in production screens first.

- `MarkdownView` — a hand-written GFM widget tree over the `markdown` parser,
  carrying a node → source-line map: tables, task lists, footnotes, alerts,
  fenced code with copy buttons, KaTeX math, Mermaid flowcharts and sequence
  diagrams, front-matter strips, heading folding.
- `ReadingMode` — the renderer plus an outline (side panel ≥ 900 px, sheet
  below), scroll-synced current-section highlight and `#anchor` jumps.
- `MdSourceController` — live syntax in an ordinary `TextField`: headings
  sized in the field, bold bold, markers dimmed off the caret's line. Never
  hidden — the controller returns every character of `text`, by contract.
- `SourceMode` — the editor surface: split preview with two-way scroll sync,
  focus mode, find & replace, slash menu, ⌘K command palette, list
  auto-continuation, smart paste.
- `MarkdownForge` seams: `MarkdownTheme`, `MarkdownStrings` (with a fold hook
  for locales the default lowercase gets wrong), `MarkdownImageResolver`, and
  a link-scheme allowlist.
