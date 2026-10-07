import 'package:flutter/material.dart';
import 'package:markdown_forge/markdown_forge.dart';

void main() => runApp(const ForgeExample());

const _sample = '''
# markdown_forge

Type on the **Edit** tab; the *Read* tab renders it with an outline.

- [x] GFM task lists
- [ ] Tables, footnotes[^1], math and diagrams

| Feature | Status |
| --- | --- |
| Live syntax | ✓ |

\$\$e^{i\\pi} + 1 = 0\$\$

```mermaid
flowchart LR
  A[Write] --> B[Render]
```

[^1]: Every block knows its source line.
''';

class ForgeExample extends StatelessWidget {
  const ForgeExample({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'markdown_forge',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const _Home(),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _controller = MdSourceController(text: _sample);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('markdown_forge'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Read'),
              Tab(text: 'Edit'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => ReadingMode(markdown: _controller.text),
            ),
            SourceMode(controller: _controller),
          ],
        ),
      ),
    );
  }
}
