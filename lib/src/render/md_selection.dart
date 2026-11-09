/// Selection that copies like a document (alliswell#43).
///
/// A `SelectionArea` alone makes the text selectable, but Flutter joins the
/// selected `Text` widgets back to back: a heading and the paragraph under it
/// come out as `Title headingFirst paragraph`, a table as `NameValuecell one`.
/// Pasted anywhere, that is not a copy of the note — it is a puzzle.
///
/// So the joins follow the layout, the way a browser's copy does:
///
/// * between top-level blocks — a blank line (`\n\n`), so paragraphs stay
///   paragraphs when pasted back into markdown;
/// * inside a block, a piece that starts BELOW the previous one starts a new
///   line (list items, table rows, quoted paragraphs);
/// * a piece BESIDE the previous one is separated by a tab (table cells, a
///   list marker and its text) — what spreadsheets and editors expect.
///
/// Blocks are joined through a [_MdCopyPass] rather than by geometry because
/// the lazy list puts a `Scrollable` between the document and its blocks, and
/// a scrollable's own selection container concatenates its children with no
/// separator at all. The document starts a pass, each block that has
/// something selected says so, and the next one leads with the blank line.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// One `getSelectedContent` walk over the document.
class _MdCopyPass {
  bool active = false;

  /// A block earlier in this walk contributed text.
  bool emitted = false;
}

class _MdCopyPassScope extends InheritedWidget {
  const _MdCopyPassScope({required this.pass, required super.child});

  final _MdCopyPass pass;

  static _MdCopyPass? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MdCopyPassScope>()?.pass;

  @override
  bool updateShouldNotify(_MdCopyPassScope old) => old.pass != pass;
}

/// The document's selection container: opens a copy pass around every read
/// of the selected text, so its blocks know which of them comes first.
///
/// It does not create a selection area — it joins whichever one is above it
/// (the view's own, or the host's).
class MdSelectionDocument extends StatefulWidget {
  const MdSelectionDocument({super.key, required this.child});

  final Widget child;

  @override
  State<MdSelectionDocument> createState() => _MdSelectionDocumentState();
}

class _MdSelectionDocumentState extends State<MdSelectionDocument> {
  final _MdCopyPass _pass = _MdCopyPass();
  late final _DocumentDelegate _delegate = _DocumentDelegate(_pass);

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionContainer(
    delegate: _delegate,
    child: _MdCopyPassScope(pass: _pass, child: widget.child),
  );
}

class _DocumentDelegate extends StaticSelectionContainerDelegate {
  _DocumentDelegate(this.pass);

  final _MdCopyPass pass;

  @override
  SelectedContent? getSelectedContent() {
    pass
      ..active = true
      ..emitted = false;
    try {
      return super.getSelectedContent();
    } finally {
      pass
        ..active = false
        ..emitted = false;
    }
  }
}

/// A group whose selected pieces are joined by layout: a new line for a piece
/// below the previous one, a tab for a piece beside it.
///
/// [documentBlock] marks a top-level block of an [MdSelectionDocument]: it
/// leads with a blank line when an earlier block was copied too. Groups nested
/// inside a block (a table's own scroll view) leave it off, or the blank line
/// would be written twice.
class MdSelectionGroup extends StatefulWidget {
  const MdSelectionGroup({
    super.key,
    required this.child,
    this.documentBlock = false,
  });

  final Widget child;
  final bool documentBlock;

  @override
  State<MdSelectionGroup> createState() => _MdSelectionGroupState();
}

class _MdSelectionGroupState extends State<MdSelectionGroup> {
  final _GroupDelegate _delegate = _GroupDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _delegate.pass = widget.documentBlock
        ? _MdCopyPassScope.maybeOf(context)
        : null;
    return SelectionContainer(delegate: _delegate, child: widget.child);
  }
}

class _GroupDelegate extends StaticSelectionContainerDelegate {
  _MdCopyPass? pass;

  /// Two pieces whose boxes overlap by less than this are on different lines.
  static const double _lineTolerance = 1;

  @override
  SelectedContent? getSelectedContent() {
    final pass = this.pass;
    final inPass = pass != null && pass.active;
    // Read BEFORE the children: a nested group must not count as "earlier".
    final lead = inPass && pass.emitted;

    final buffer = StringBuffer();
    Rect? previous;
    for (final selectable in selectables) {
      final text = selectable.getSelectedContent()?.plainText;
      if (text == null || text.isEmpty) continue;
      final rect = MatrixUtils.transformRect(
        selectable.getTransformTo(null),
        Offset.zero & selectable.size,
      );
      if (previous != null) {
        buffer.write(
          rect.top >= previous.bottom - _lineTolerance ? '\n' : '\t',
        );
      }
      buffer.write(text);
      previous = rect;
    }
    if (previous == null) return null;

    var joined = buffer.toString();
    if (inPass) {
      // A fenced block's source ends in a newline; the blank line before the
      // next block is written by that block, not doubled here.
      joined = joined.replaceFirst(RegExp(r'\n+$'), '');
      if (joined.isEmpty) return null;
      pass.emitted = true;
      if (lead) joined = '\n\n$joined';
    }
    return SelectedContent(plainText: joined);
  }
}
