import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markdown_forge/markdown_forge.dart';

/// Issue alliswell#43 — text in the reading view and the split preview could
/// not be selected or copied, because every block was a plain `Text` and
/// nothing put them inside a selection area. Only code blocks (each its own
/// `SelectableText`) could be selected, one block at a time.
///
/// These tests drive selection the way Flutter's own `SelectableRegion` tests
/// do: a mouse click focuses the region, Ctrl+A selects all, Ctrl+C copies,
/// and a mocked platform channel catches what reached the clipboard.
const _doc = '''
# Title heading

First paragraph with a [link](https://example.com/page) inside.

- item one
- [x] done task

> quoted line

| Name | Value |
| ---- | ----- |
| cell one | cell two |

```dart
void main() {}
```

![picture](https://example.com/a.png)

Last paragraph.
''';

/// Catches `Clipboard.setData` so a copy can be read back.
class _Clipboard {
  Map<String, dynamic>? data;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        data = Map<String, dynamic>.from(call.arguments as Map);
      case 'Clipboard.getData':
        return data;
      case 'Clipboard.hasStrings':
        final text = data?['text'] as String?;
        return {'value': text != null && text.isNotEmpty};
    }
    return null;
  }

  String? get text => data?['text'] as String?;
}

_Clipboard _mockClipboard(WidgetTester tester) {
  final clipboard = _Clipboard();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    clipboard.handle,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return clipboard;
}

/// Images resolve to a plain box: no network in a widget test.
MarkdownImage _resolver(String source, String alt) => MarkdownImageWidget(
  (_) => SizedBox(key: Key('img-$source'), width: 40, height: 40),
);

Widget _host(Widget child, {ThemeData? theme}) => MarkdownForge(
  imageResolver: _resolver,
  child: MaterialApp(
    theme: theme,
    home: Scaffold(body: child),
  ),
);

RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: find.text(text), matching: find.byType(RichText)),
    );

/// The global position of character [offset] in the paragraph showing [text].
Offset _at(WidgetTester tester, String text, int offset) {
  final paragraph = _paragraph(tester, text);
  final caret = paragraph.getOffsetForCaret(
    TextPosition(offset: offset),
    Rect.zero,
  );
  return paragraph.localToGlobal(
    caret + Offset(0, paragraph.preferredLineHeight / 2),
  );
}

/// A mouse drag from [from] to [to], then Ctrl+C.
Future<String?> _dragAndCopy(
  WidgetTester tester,
  Offset from,
  Offset to,
) async {
  final clipboard = _mockClipboard(tester);
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pump();

  await _keys(tester, LogicalKeyboardKey.keyC);
  await tester.pumpAndSettle();
  return clipboard.text;
}

Future<void> _useSurface(WidgetTester tester, Size size) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _keys(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Click on [finder] (focusing the selection region), Ctrl+A, Ctrl+C.
Future<String?> _selectAllAndCopy(WidgetTester tester, Finder finder) async {
  final clipboard = _mockClipboard(tester);
  // Nested selection containers register their children after a frame, as
  // they do in the app before anyone can click.
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(
    tester.getTopLeft(finder) + const Offset(2, 2),
    kind: PointerDeviceKind.mouse,
  );
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 500));

  await _keys(tester, LogicalKeyboardKey.keyA);
  // A person's Ctrl+A → Ctrl+C takes longer than the two frames in which a
  // lazy list builds and registers the blocks that were off screen.
  await tester.pumpAndSettle();
  await _keys(tester, LogicalKeyboardKey.keyC);
  await tester.pumpAndSettle();
  return clipboard.text;
}

/// What a full copy of [_doc] must contain, as ONE selection, in order —
/// and laid out like the page, not run together: a blank line between
/// blocks, a newline between list items and table rows, a tab between cells.
void _expectWholeDocument(String? copied) {
  expect(copied, isNotNull, reason: 'nothing reached the clipboard');
  final text = copied!;
  const inOrder = [
    'Title heading',
    'First paragraph with a link inside.',
    'item one',
    'done task',
    'quoted line',
    'cell one',
    'cell two',
    'void main() {}',
    'picture',
    'Last paragraph.',
  ];
  var from = 0;
  for (final part in inOrder) {
    final at = text.indexOf(part, from);
    expect(at, greaterThanOrEqualTo(0), reason: '"$part" missing in: $text');
    from = at + part.length;
  }
  expect(text, startsWith('Title heading\n\nFirst paragraph'));
  expect(text, contains('inside.\n\n•\titem one\ndone task\n\nquoted line'));
  expect(text, contains('Name\tValue\ncell one\tcell two'));
  // The code joins as code: no language label in front, no extra newline.
  expect(text, contains('cell two\n\nvoid main() {}\n\n'));
  // The image is not a hole in the copy: its alt text stands in for it.
  expect(text, contains('void main() {}\n\npicture\n\nLast paragraph.'));
  expect(text, endsWith('Last paragraph.'));
}

/// A note far taller than the screen: 200 one-line paragraphs.
final _longDoc = [
  for (var i = 0; i < 200; i++) 'Paragraph number $i.',
].join('\n\n');

/// Every paragraph of [_longDoc], in order, a blank line apart.
void _expectWholeLongDoc(String? copied) {
  expect(copied, isNotNull, reason: 'nothing reached the clipboard');
  final blocks = copied!.split('\n\n');
  expect(blocks, hasLength(200), reason: 'only ${blocks.length} blocks');
  expect(blocks.first, 'Paragraph number 0.');
  expect(blocks.last, 'Paragraph number 199.');
}

void main() {
  group('MarkdownView', () {
    testWidgets('puts the document inside one selection area', (tester) async {
      await tester.pumpWidget(
        _host(MarkdownView(document: parseMarkdown(_doc))),
      );

      expect(find.byType(SelectionArea), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('Last paragraph.'),
          matching: find.byType(SelectableRegion),
        ),
        findsOneWidget,
      );
      // Code joins the same selection instead of being a region of its own.
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('select all + copy takes every block as one selection', (
      tester,
    ) async {
      await _useSurface(tester, const Size(800, 2000));
      await tester.pumpWidget(
        _host(MarkdownView(document: parseMarkdown(_doc))),
      );

      _expectWholeDocument(
        await _selectAllAndCopy(tester, find.text('Last paragraph.')),
      );
    });

    testWidgets('the shrink-wrapped path is selectable too', (tester) async {
      await _useSurface(tester, const Size(800, 2000));
      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            child: MarkdownView(
              document: parseMarkdown(_doc),
              shrinkWrap: true,
            ),
          ),
        ),
      );

      _expectWholeDocument(
        await _selectAllAndCopy(tester, find.text('Last paragraph.')),
      );
    });

    testWidgets('a drag inside one paragraph copies just those words', (
      tester,
    ) async {
      await _useSurface(tester, const Size(800, 2000));
      await tester.pumpWidget(
        _host(MarkdownView(document: parseMarkdown(_doc))),
      );
      await tester.pumpAndSettle();

      const line = 'First paragraph with a link inside.';
      final copied = await _dragAndCopy(
        tester,
        _at(tester, line, 0),
        _at(tester, line, 'First paragraph'.length),
      );
      // No blank line in front: nothing before it was copied.
      expect(copied, 'First paragraph');
    });

    testWidgets('a drag across two blocks copies both, a blank line apart', (
      tester,
    ) async {
      await _useSurface(tester, const Size(800, 2000));
      await tester.pumpWidget(
        _host(MarkdownView(document: parseMarkdown(_doc))),
      );
      await tester.pumpAndSettle();

      final copied = await _dragAndCopy(
        tester,
        _at(tester, 'Title heading', 'Title '.length),
        _at(tester, 'First paragraph with a link inside.', 'First'.length),
      );
      expect(copied, 'heading\n\nFirst');
    });

    testWidgets('the highlight is the theme\'s, in dark as in light', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        final theme = ThemeData(brightness: brightness);
        await tester.pumpWidget(
          _host(
            MarkdownView(document: parseMarkdown('Hello there.')),
            theme: theme,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          _paragraph(tester, 'Hello there.').selectionColor,
          theme.colorScheme.primary.withValues(alpha: 0.40),
          reason: '$brightness',
        );
      }
    });

    testWidgets('does not nest inside a host selection area', (tester) async {
      await tester.pumpWidget(
        _host(
          SelectionArea(
            child: MarkdownView(document: parseMarkdown('Hello there.')),
          ),
        ),
      );

      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.byType(SelectableRegion), findsOneWidget);
    });

    testWidgets('selectable: false opts out', (tester) async {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            document: parseMarkdown('Hello there.'),
            selectable: false,
          ),
        ),
      );

      expect(find.byType(SelectableRegion), findsNothing);
    });

    testWidgets('a link tap still opens the link', (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        _host(
          MarkdownView(
            document: parseMarkdown('[open me](https://example.com/x)'),
            onOpenLink: opened.add,
          ),
        ),
      );

      await tester.tapOnText(find.textRange.ofSubstring('open me'));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://example.com/x')]);
    });

    testWidgets('an image tap still reaches onTapImage', (tester) async {
      final taps = <MdGallery>[];
      await tester.pumpWidget(
        _host(
          MarkdownView(
            document: parseMarkdown('![a](https://example.com/a.png)'),
            onTapImage: taps.add,
          ),
        ),
      );

      await tester.tap(find.byType(MdImage));
      await tester.pumpAndSettle();
      expect(taps, hasLength(1));
      expect(taps.single.sources, ['https://example.com/a.png']);
    });

    testWidgets('the code block copy button still copies the code', (
      tester,
    ) async {
      final clipboard = _mockClipboard(tester);
      await tester.pumpWidget(
        _host(
          MarkdownView(document: parseMarkdown('```dart\nvoid main() {}\n```')),
        ),
      );

      await tester.tap(find.byKey(const Key('md-copy-code')));
      await tester.pump();
      expect(clipboard.text, 'void main() {}\n');
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });
  });

  group('MarkdownView, a document taller than the screen', () {
    // The lazy list builds only the blocks near the screen; a selection can
    // only reach blocks that exist. Before the fix a select-all here copied
    // 26 of 200 paragraphs and said nothing.
    testWidgets('select all + copy takes the blocks that are off screen', (
      tester,
    ) async {
      await _useSurface(tester, const Size(800, 600));
      await tester.pumpWidget(
        _host(MarkdownView(document: parseMarkdown(_longDoc))),
      );
      expect(find.text('Paragraph number 199.'), findsNothing);

      _expectWholeLongDoc(
        await _selectAllAndCopy(tester, find.text('Paragraph number 0.')),
      );
    });

    testWidgets('a selection survives scrolling far past it', (tester) async {
      await _useSurface(tester, const Size(800, 600));
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        _host(
          MarkdownView(document: parseMarkdown(_longDoc), controller: scroll),
        ),
      );
      await tester.pumpAndSettle();

      final clipboard = _mockClipboard(tester);
      final gesture = await tester.startGesture(
        _at(tester, 'Paragraph number 0.', 0),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(
        _at(tester, 'Paragraph number 1.', 'Paragraph'.length),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Far beyond any cache extent: a lazily dropped block would take its
      // part of the selection with it.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();

      await _keys(tester, LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      expect(clipboard.text, 'Paragraph number 0.\n\nParagraph');
    });

    testWidgets('a cleared selection lets the list go lazy again', (
      tester,
    ) async {
      await _useSurface(tester, const Size(800, 600));
      await tester.pumpWidget(
        _host(MarkdownView(document: parseMarkdown(_longDoc))),
      );
      await _selectAllAndCopy(tester, find.text('Paragraph number 0.'));
      expect(
        find.text('Paragraph number 199.', skipOffstage: false),
        findsOneWidget,
      );

      // A click clears the selection.
      await tester.tapAt(_at(tester, 'Paragraph number 0.', 3));
      await tester.pumpAndSettle();
      expect(
        find.text('Paragraph number 199.', skipOffstage: false),
        findsNothing,
      );
    });

    final touch = TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    });

    testWidgets('touch: long-press, Select all, Copy takes the whole note', (
      tester,
    ) async {
      await _useSurface(tester, const Size(400, 800));
      final clipboard = _mockClipboard(tester);
      // Room above the note, as a screen's app bar gives it: the toolbar goes
      // above the selection's start, and a select-all's end is off screen.
      await tester.pumpWidget(
        _host(
          Padding(
            padding: const EdgeInsets.only(top: 120),
            child: MarkdownView(document: parseMarkdown(_longDoc)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPressAt(_at(tester, 'Paragraph number 2.', 2));
      await tester.pumpAndSettle();

      final selectAll = find.textContaining(RegExp('Select [Aa]ll'));
      expect(selectAll, findsOneWidget, reason: 'no selection toolbar');
      await tester.tap(selectAll);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      _expectWholeLongDoc(clipboard.text);
    }, variant: touch);

    testWidgets('touch: long-press a word, Copy', (tester) async {
      final clipboard = _mockClipboard(tester);
      await tester.pumpWidget(
        _host(MarkdownView(document: parseMarkdown('Hello there friend.'))),
      );
      await tester.pumpAndSettle();

      await tester.longPressAt(
        _at(tester, 'Hello there friend.', 'Hello th'.length),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(clipboard.text, 'there');
    }, variant: touch);
  });

  group('MarkdownView, formulas and images', () {
    testWidgets('a copy keeps inline math as TeX and an image as its alt', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            document: parseMarkdown(
              r'Value $x^2$ is big. See ![a cat](https://example.com/a.png) here',
            ),
          ),
        ),
      );

      expect(
        await _selectAllAndCopy(tester, find.byType(RichText).first),
        r'Value $x^2$ is big. See a cat here',
      );
    });

    testWidgets('a copy keeps display math as a fenced block', (tester) async {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            document: parseMarkdown(
              'Before.\n\n\$\$\nE = mc^2\n\$\$\n\nAfter.',
            ),
          ),
        ),
      );

      expect(
        await _selectAllAndCopy(tester, find.text('Before.')),
        'Before.\n\n\$\$\nE = mc^2\n\$\$\n\nAfter.',
      );
    });

    testWidgets('a drag that stops before a formula leaves it out', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            document: parseMarkdown(r'Lead words then $y$ and more.'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final paragraph = find.byType(RichText).first;
      final start = tester.getTopLeft(paragraph) + const Offset(1, 8);

      final copied = await _dragAndCopy(
        tester,
        start,
        start + const Offset(30, 0),
      );
      expect(copied, isNot(contains(r'$y$')));
      expect(copied, isNotEmpty);
    });
  });

  group('selection setups around the view', () {
    testWidgets('a host that disabled selection keeps it disabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SelectionArea(
            child: SelectionContainer.disabled(
              child: MarkdownView(
                document: parseMarkdown('Hello there.\n\n```\ncode\n```'),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SelectableRegion), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('a code block on its own is still selectable', (tester) async {
      await tester.pumpWidget(
        _host(const MdCodeBlock(source: 'void main() {}', language: 'dart')),
      );

      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('an unsupported block on its own is still selectable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const MdUnsupportedBlock(
            reason: 'cannot be drawn',
            source: '<raw stuff>',
          ),
        ),
      );

      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('selectable: false leaves code blocks unselectable too', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            document: parseMarkdown('```\ncode\n```'),
            selectable: false,
          ),
        ),
      );

      expect(find.byType(SelectableRegion), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
    });
  });

  group('ReadingMode', () {
    testWidgets('select all + copy takes a note taller than the screen', (
      tester,
    ) async {
      await _useSurface(tester, const Size(800, 600));
      await tester.pumpWidget(_host(ReadingMode(markdown: _longDoc)));
      await tester.pumpAndSettle();

      _expectWholeLongDoc(
        await _selectAllAndCopy(tester, find.text('Paragraph number 0.')),
      );
    });

    testWidgets('select all + copy takes the whole note', (tester) async {
      await _useSurface(tester, const Size(800, 2000));
      await tester.pumpWidget(_host(const ReadingMode(markdown: _doc)));
      await tester.pumpAndSettle();

      expect(
        find.ancestor(
          of: find.byKey(const Key('note-reading')),
          matching: find.byType(SelectionArea),
        ),
        findsNothing,
        reason: 'the area belongs to the document, not the whole screen',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('note-reading')),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
      _expectWholeDocument(
        await _selectAllAndCopy(tester, find.text('Last paragraph.')),
      );
    });

    testWidgets('folding a heading from the outline still works', (
      tester,
    ) async {
      await _useSurface(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(const ReadingMode(markdown: '# One\n\nhidden body\n\n# Two\n')),
      );
      await tester.pumpAndSettle();
      expect(find.text('hidden body'), findsOneWidget);

      await tester.tap(find.byKey(const Key('outline-fold-one')));
      await tester.pumpAndSettle();
      expect(find.text('hidden body'), findsNothing);
    });
  });

  group('SourceMode split preview', () {
    testWidgets('the preview pane is selectable', (tester) async {
      await _useSurface(tester, const Size(1400, 2000));
      final controller = MdSourceController(text: _doc);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(SourceMode(controller: controller)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('note-split-toggle')));
      await tester.pumpAndSettle();

      final preview = find.byKey(const Key('note-split-preview'));
      expect(preview, findsOneWidget);
      expect(
        find.descendant(of: preview, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      _expectWholeDocument(
        await _selectAllAndCopy(
          tester,
          find.descendant(of: preview, matching: find.text('Last paragraph.')),
        ),
      );
    });
  });
}
