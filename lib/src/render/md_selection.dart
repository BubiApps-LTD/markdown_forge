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
///
/// Two more things a plain `SelectionArea` gets wrong for a document:
///
/// * a LAZY list only builds the blocks near the screen, so a select-all
///   would copy those and silently drop the rest. [MdSelectionDocument]
///   reports when a selection exists ([MdSelectionDocument.onActiveChanged])
///   so the view can build every block while one does, and repeats a
///   select-all once the newly built blocks have joined;
/// * a formula or an image is a widget, not text, and would vanish from a
///   copy. [MdSelectableAtom] makes it one selectable unit that copies as the
///   text it stands for (the TeX source, the alt text).
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// What selection setup a widget sits under.
enum MdSelectionScope {
  /// No selection area above: a standalone widget.
  none,

  /// A host turned selection off (`SelectionContainer.disabled`).
  disabled,

  /// Inside a live selection area or container.
  enabled,
}

/// Tells "no selection area at all" apart from "an area that a host turned
/// off": `SelectionContainer.maybeOf` answers null for both, and treating the
/// second like the first would switch selection back on where a host
/// deliberately turned it off.
MdSelectionScope mdSelectionScopeOf(BuildContext context) {
  final scope = context
      .dependOnInheritedWidgetOfExactType<SelectionRegistrarScope>();
  if (scope == null) return MdSelectionScope.none;
  return scope.registrar == null
      ? MdSelectionScope.disabled
      : MdSelectionScope.enabled;
}

/// Our containers sit three deep (document, scrollable, block, text), and
/// Flutter registers each level with the one above a step later. The step
/// after a frame runs in a microtask, when no frame is in progress; there the
/// next level's registration waits for a frame nobody has asked for, so on a
/// still screen a long-press finds an empty document until something else
/// redraws. Asking for that frame closes the gap.
void _frameForPendingRegistrations() {
  final binding = SchedulerBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.idle) binding.scheduleFrame();
}

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
  const MdSelectionDocument({
    super.key,
    required this.child,
    this.onActiveChanged,
  });

  final Widget child;

  /// Called with `true` when some text in the document becomes selected and
  /// with `false` when the selection is gone or collapses to a point. The
  /// lazy list uses it to build every block while text is selected, so a
  /// select-all does not miss the blocks that are off screen.
  final ValueChanged<bool>? onActiveChanged;

  @override
  State<MdSelectionDocument> createState() => _MdSelectionDocumentState();
}

class _MdSelectionDocumentState extends State<MdSelectionDocument> {
  final _MdCopyPass _pass = _MdCopyPass();
  late final _DocumentDelegate _delegate = _DocumentDelegate(_pass)
    ..addListener(_selectionChanged);
  bool _active = false;

  void _selectionChanged() {
    // A collapsed selection (where a click landed) has nothing to copy and
    // must not make the list build the whole document.
    final active = _delegate.value.status == SelectionStatus.uncollapsed;
    if (active == _active) return;
    _active = active;
    final report = widget.onActiveChanged;
    if (report == null) return;
    // Geometry can change while the tree is being built or laid out (a block
    // leaving the list); the host's setState waits for the frame to end.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active == active) report(active);
      });
    } else {
      report(active);
    }
  }

  @override
  void dispose() {
    _delegate
      ..removeListener(_selectionChanged)
      ..dispose();
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

  /// The last event was a select-all: blocks that join later belong in it.
  bool _selectAll = false;
  bool _reselectScheduled = false;
  bool _disposed = false;

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    _selectAll = event.type == SelectionEventType.selectAll;
    final result = super.dispatchSelectionEvent(event);
    if (_selectAll) _scheduleReselect();
    return result;
  }

  /// A select-all reaches only the blocks that exist when it is sent. A lazy
  /// list builds the rest on the next frame (see
  /// [MdSelectionDocument.onActiveChanged]) and they register a frame after
  /// that, so the select-all is sent again once they have — and again right
  /// before a copy, in case the copy comes first.
  void _scheduleReselect() {
    if (_reselectScheduled) return;
    _reselectScheduled = true;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      binding.addPostFrameCallback((_) {
        _reselectScheduled = false;
        _reselectAll();
      });
      binding.scheduleFrame();
    });
    binding.scheduleFrame();
  }

  void _reselectAll() {
    if (_disposed || !_selectAll) return;
    super.dispatchSelectionEvent(const SelectAllSelectionEvent());
  }

  @override
  void didChangeSelectables() {
    super.didChangeSelectables();
    _frameForPendingRegistrations();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  SelectedContent? getSelectedContent() {
    _reselectAll();
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

  @override
  void didChangeSelectables() {
    super.didChangeSelectables();
    _frameForPendingRegistrations();
  }

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

/// A widget that selects as ONE unit and copies as [text] — a formula as its
/// TeX source, an image as its alt text (alliswell#43).
///
/// Without it a formula or a picture inside a selection is a hole: the copy
/// skips it and leaves the two spaces around it touching. With it the unit is
/// selected whole or not at all, highlighted over its box, and a copy puts
/// [text] where it stood.
///
/// Outside a selection area, or with an empty [text], it is just [child].
class MdSelectableAtom extends StatelessWidget {
  const MdSelectableAtom({super.key, required this.text, required this.child});

  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    if (registrar == null || text.isEmpty) return child;
    return _AtomAdapter(
      registrar: registrar,
      text: text,
      selectionColor:
          DefaultSelectionStyle.of(context).selectionColor ??
          DefaultSelectionStyle.defaultColor,
      // Whatever text the child draws (a formula's error fallback, an image
      // chip's label) is not copied a second time: [text] stands for it.
      child: SelectionContainer.disabled(child: child),
    );
  }
}

class _AtomAdapter extends SingleChildRenderObjectWidget {
  const _AtomAdapter({
    required this.registrar,
    required this.text,
    required this.selectionColor,
    required Widget super.child,
  });

  final SelectionRegistrar registrar;
  final String text;
  final Color selectionColor;

  @override
  _RenderAtom createRenderObject(BuildContext context) => _RenderAtom(
    registrar: registrar,
    text: text,
    selectionColor: selectionColor,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderAtom renderObject) {
    renderObject
      ..text = text
      ..selectionColor = selectionColor
      ..registrar = registrar;
  }
}

/// One selectable unit. Each selection edge is only ever BEFORE or AFTER the
/// atom in reading order (a point above it, or left of its middle on its
/// line, is before); the atom is selected when the two edges fall on
/// different sides of it.
class _RenderAtom extends RenderProxyBox with Selectable, SelectionRegistrant {
  _RenderAtom({
    required SelectionRegistrar registrar,
    required this.text,
    required Color selectionColor,
  }) : _selectionColor = selectionColor {
    this.registrar = registrar;
    _geometry.addListener(markNeedsPaint);
  }

  static const SelectionGeometry _none = SelectionGeometry(
    status: SelectionStatus.none,
    hasContent: true,
  );

  final ValueNotifier<SelectionGeometry> _geometry = ValueNotifier(_none);

  String text;

  Color get selectionColor => _selectionColor;
  Color _selectionColor;
  set selectionColor(Color value) {
    if (value == _selectionColor) return;
    _selectionColor = value;
    markNeedsPaint();
  }

  /// `false` = the edge is before the atom, `true` = after, null = unset.
  bool? _startAfter;
  bool? _endAfter;

  bool get _selected =>
      _startAfter != null && _endAfter != null && _startAfter != _endAfter;

  bool _isAfter(Offset local) {
    if (local.dy < 0) return false;
    if (local.dy > size.height) return true;
    return local.dx >= size.width / 2;
  }

  @override
  void addListener(VoidCallback listener) => _geometry.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _geometry.removeListener(listener);

  @override
  SelectionGeometry get value => _geometry.value;

  @override
  List<Rect> get boundingBoxes => [paintBounds];

  void _updateGeometry() {
    if (!_selected) {
      _geometry.value = _none;
      return;
    }
    final rect = Offset.zero & size;
    final first = SelectionPoint(
      localPosition: rect.bottomLeft,
      lineHeight: size.height,
      handleType: TextSelectionHandleType.left,
    );
    final last = SelectionPoint(
      localPosition: rect.bottomRight,
      lineHeight: size.height,
      handleType: TextSelectionHandleType.right,
    );
    final reversed = _startAfter!;
    _geometry.value = SelectionGeometry(
      status: SelectionStatus.uncollapsed,
      hasContent: true,
      startSelectionPoint: reversed ? last : first,
      endSelectionPoint: reversed ? first : last,
      selectionRects: [rect],
    );
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    var result = SelectionResult.none;
    switch (event.type) {
      case SelectionEventType.startEdgeUpdate:
      case SelectionEventType.endEdgeUpdate:
        final local = globalToLocal(
          (event as SelectionEdgeUpdateEvent).globalPosition,
        );
        final after = _isAfter(local);
        if (event.type == SelectionEventType.startEdgeUpdate) {
          _startAfter = after;
        } else {
          _endAfter = after;
        }
        result = SelectionUtils.getResultBasedOnRect(Offset.zero & size, local);
      case SelectionEventType.clear:
        _startAfter = _endAfter = null;
      case SelectionEventType.selectAll:
      case SelectionEventType.selectWord:
      case SelectionEventType.selectParagraph:
        _startAfter = false;
        _endAfter = true;
        result = SelectionResult.end;
      case SelectionEventType.granularlyExtendSelection:
        final extend = event as GranularlyExtendSelectionEvent;
        result = _extend(extend.isEnd, extend.forward, extend.forward);
      case SelectionEventType.directionallyExtendSelection:
        final extend = event as DirectionallyExtendSelectionEvent;
        final baseline = globalToLocal(Offset(extend.dx, 0)).dx;
        final forward = switch (extend.direction) {
          SelectionExtendDirection.forward ||
          SelectionExtendDirection.nextLine => true,
          SelectionExtendDirection.backward ||
          SelectionExtendDirection.previousLine => false,
        };
        final after = switch (extend.direction) {
          SelectionExtendDirection.nextLine ||
          SelectionExtendDirection.previousLine => forward,
          SelectionExtendDirection.forward => baseline > size.width,
          SelectionExtendDirection.backward => !(baseline < 0),
        };
        result = _extend(extend.isEnd, forward, after);
    }
    _updateGeometry();
    return result;
  }

  /// Moves one edge to [after]; a selection that does not exist yet starts
  /// collapsed on the side the movement comes from.
  SelectionResult _extend(bool isEnd, bool forward, bool after) {
    if (_startAfter == null || _endAfter == null) {
      _startAfter = _endAfter = !forward;
    }
    final unchanged = (isEnd ? _endAfter : _startAfter) == after;
    if (isEnd) {
      _endAfter = after;
    } else {
      _startAfter = after;
    }
    if (!unchanged) return SelectionResult.end;
    return forward ? SelectionResult.next : SelectionResult.previous;
  }

  @override
  SelectedContent? getSelectedContent() =>
      _selected ? SelectedContent(plainText: text) : null;

  @override
  SelectedContentRange? getSelection() {
    if (!_selected) return null;
    return _startAfter!
        ? SelectedContentRange(startOffset: text.length, endOffset: 0)
        : SelectedContentRange(startOffset: 0, endOffset: text.length);
  }

  @override
  int get contentLength => text.length;

  LayerLink? _startHandle;
  LayerLink? _endHandle;

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_startHandle == startHandle && _endHandle == endHandle) return;
    _startHandle = startHandle;
    _endHandle = endHandle;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final geometry = _geometry.value;
    if (!geometry.hasSelection) return;
    context.canvas.drawRect(
      (Offset.zero & size).shift(offset),
      Paint()..color = _selectionColor,
    );
    void lead(LayerLink? link, SelectionPoint? point) {
      if (link == null || point == null) return;
      context.pushLayer(
        LeaderLayer(link: link, offset: offset + point.localPosition),
        (_, _) {},
        Offset.zero,
      );
    }

    lead(_startHandle, geometry.startSelectionPoint);
    lead(_endHandle, geometry.endSelectionPoint);
  }

  @override
  void dispose() {
    _startHandle = _endHandle = null;
    super.dispose();
    _geometry.dispose();
  }
}
