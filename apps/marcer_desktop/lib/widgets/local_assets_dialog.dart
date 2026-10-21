// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../local_assets.dart';
import '../open_local_file.dart';

/// Opens the box-scan gallery: one section per edition with bounded-decode
/// thumbnails; a thumbnail opens the full-screen image viewer.
Future<void> showBoxscanGallery(
  BuildContext context, {
  required LocalGameAssets assets,
  required LocalAssetsService service,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _BoxscanGalleryDialog(assets: assets, service: service),
  );
}

/// Opens the manual list: grouped by stem, with Scan/Text PDFs, image pages and
/// document rows. PDFs/DOC/TXT open in the OS default app; image pages open in
/// the in-app viewer; `.msa` is shown as an info-only disk image.
Future<void> showManualDialog(
  BuildContext context, {
  required LocalGameAssets assets,
  required LocalAssetsService service,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ManualDialog(assets: assets, service: service),
  );
}

/// Full-screen viewer for locally discovered images (`←/→`, `Esc`, zoom).
Future<void> showLocalImageViewer(
  BuildContext context, {
  required List<LocalImageRef> items,
  required int initialIndex,
  required LocalAssetsService service,
}) {
  if (items.isEmpty) return Future.value();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => _LocalImageViewer(
      items: items,
      initialIndex: initialIndex.clamp(0, items.length - 1),
      service: service,
    ),
  );
}

class _DialogShell extends StatelessWidget {
  const _DialogShell({
    required this.title,
    required this.child,
    this.width = 1000,
    this.height = 820,
  });

  final String title;
  final Widget child;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: const Color(0xFF0D0D0D),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(width, size.width - 40),
        height: math.min(height, size.height - 40),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close (Esc)',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- box scans

class _BoxscanGalleryDialog extends StatefulWidget {
  const _BoxscanGalleryDialog({required this.assets, required this.service});

  final LocalGameAssets assets;
  final LocalAssetsService service;

  @override
  State<_BoxscanGalleryDialog> createState() => _BoxscanGalleryDialogState();
}

class _BoxscanGalleryDialogState extends State<_BoxscanGalleryDialog> {
  final Map<String, Map<String, String>> _paths = {};
  final Set<String> _loading = {};

  Future<void> _load(LocalBoxscanEdition edition) async {
    if (!mounted) return;
    if (_paths.containsKey(edition.label) || !_loading.add(edition.label)) {
      return;
    }
    setState(() {});
    final paths = await widget.service.materializeEdition(edition);
    if (!mounted) return;
    setState(() {
      _paths[edition.label] = paths;
      _loading.remove(edition.label);
    });
  }

  Future<void> _retry(LocalBoxscanEdition edition, LocalImageRef image) async {
    final path = await widget.service.materializeImage(image);
    if (!mounted) return;
    if (path == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text('Could not read ${image.name}.'),
        duration: const Duration(seconds: 4),
      ));
      return;
    }
    setState(() {
      (_paths[edition.label] ??= <String, String>{})[image.cacheKey] = path;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: 'Box scans — ${widget.assets.boxscans.length} edition'
          '${widget.assets.boxscans.length == 1 ? '' : 's'}, '
          '${widget.assets.boxscanImageCount} images',
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: widget.assets.boxscans.length,
        itemBuilder: (context, i) {
          final edition = widget.assets.boxscans[i];
          final paths = _paths[edition.label];
          final loading = _loading.contains(edition.label);
          if (paths == null && !loading) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _load(edition));
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  edition.label,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Extracting…',
                            style:
                                TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  )
                else
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var j = 0; j < edition.images.length; j++)
                        _BoxscanThumb(
                          image: edition.images[j],
                          path: paths?[edition.images[j].cacheKey],
                          onOpen: paths?[edition.images[j].cacheKey] == null
                              ? null
                              : () => showLocalImageViewer(
                                    context,
                                    items: edition.images,
                                    initialIndex: j,
                                    service: widget.service,
                                  ),
                          onRetry: () => _retry(edition, edition.images[j]),
                        ),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BoxscanThumb extends StatelessWidget {
  const _BoxscanThumb({
    required this.image,
    required this.path,
    required this.onOpen,
    required this.onRetry,
  });

  final LocalImageRef image;
  final String? path;
  final VoidCallback? onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final Widget content = path != null
        ? Image.file(
            File(path!),
            fit: BoxFit.contain,
            cacheWidth: 300,
            errorBuilder: (_, _, _) => const _BrokenImage(),
          )
        : InkWell(
            onTap: onRetry,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BrokenImage(),
                  SizedBox(height: 4),
                  Text('Retry',
                      style:
                          TextStyle(fontSize: 11, color: Colors.lightBlue)),
                ],
              ),
            ),
          );
    return Tooltip(
      message: image.name,
      child: SizedBox(
        width: 150,
        height: 190,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(color: const Color(0xFF2A2A2A)),
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.antiAlias,
            child: content,
          ),
        ),
      ),
    );
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) => const Center(
        child: Icon(Icons.broken_image_outlined, size: 22, color: Colors.grey),
      );
}

// ------------------------------------------------------------------ manuals

class _ManualDialog extends StatelessWidget {
  const _ManualDialog({required this.assets, required this.service});

  final LocalGameAssets assets;
  final LocalAssetsService service;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<LocalManualDoc>>{};
    for (final doc in assets.manuals) {
      groups.putIfAbsent(doc.stem.toLowerCase(), () => []).add(doc);
    }
    final stems = groups.keys.toList()..sort();
    return _DialogShell(
      title: 'Manuals — ${assets.manuals.length} file'
          '${assets.manuals.length == 1 ? '' : 's'}',
      width: 760,
      height: 760,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: stems.length,
        itemBuilder: (context, i) {
          final docs = groups[stems[i]]!;
          final title = docs.first.stem;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                for (final doc in docs)
                  _ManualRow(doc: doc, service: service),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ManualRow extends StatefulWidget {
  const _ManualRow({required this.doc, required this.service});

  final LocalManualDoc doc;
  final LocalAssetsService service;

  @override
  State<_ManualRow> createState() => _ManualRowState();
}

class _ManualRowState extends State<_ManualRow> {
  bool _busy = false;
  String? _error;

  IconData get _icon => switch (widget.doc.kind) {
        LocalManualKind.pdf => Icons.picture_as_pdf_outlined,
        LocalManualKind.imagePages => Icons.photo_library_outlined,
        LocalManualKind.document => Icons.description_outlined,
        LocalManualKind.diskImage => Icons.save_outlined,
      };

  String get _kindLabel {
    final doc = widget.doc;
    return switch (doc.kind) {
      LocalManualKind.pdf => doc.textVariant ? 'Text (PDF)' : 'Scan (PDF)',
      LocalManualKind.imagePages => 'Pages (${doc.images.length} images)',
      LocalManualKind.document =>
        'Document (${_extension(doc.label).toUpperCase()})',
      LocalManualKind.diskImage => 'Disk image (.msa)',
    };
  }

  static String _extension(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1);
  }

  Future<void> _open() async {
    final doc = widget.doc;
    if (doc.kind == LocalManualKind.diskImage) {
      _snack('Original disk image — not a document, not opened.');
      return;
    }
    if (doc.kind == LocalManualKind.imagePages) {
      await showLocalImageViewer(context,
          items: doc.images, initialIndex: 0, service: widget.service);
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final path = await widget.service.materializeDoc(doc);
    if (!mounted) return;
    if (path == null) {
      setState(() {
        _busy = false;
        _error = 'Could not read ${doc.label}.';
      });
      return;
    }
    setState(() => _busy = false);
    final ok = await openLocalFile(path);
    if (!ok && mounted) {
      setState(() => _error = 'Could not open ${doc.label}.');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final disk = doc.kind == LocalManualKind.diskImage;
    return InkWell(
      onTap: _open,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(
          children: [
            Icon(_icon, size: 17, color: disk ? Colors.grey : Colors.lightBlue),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _kindLabel,
                    style: TextStyle(
                        fontSize: 12,
                        color: disk ? Colors.grey : Colors.white),
                  ),
                  Text(
                    '${doc.label}${doc.sizeBytes > 0 ? '  ·  ${_formatBytes(doc.sizeBytes)}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10, color: Colors.redAccent),
                    ),
                ],
              ),
            ),
            if (_busy)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_error != null)
              TextButton(
                onPressed: _open,
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Retry', style: TextStyle(fontSize: 11)),
              )
            else
              Icon(disk ? Icons.info_outline : Icons.open_in_new,
                  size: 15, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

// ------------------------------------------------------------- image viewer

class _LocalImageViewer extends StatefulWidget {
  const _LocalImageViewer({
    required this.items,
    required this.initialIndex,
    required this.service,
  });

  final List<LocalImageRef> items;
  final int initialIndex;
  final LocalAssetsService service;

  @override
  State<_LocalImageViewer> createState() => _LocalImageViewerState();
}

class _LocalImageViewerState extends State<_LocalImageViewer> {
  late int _index = widget.initialIndex;

  void _prev() {
    if (_index > 0) setState(() => _index--);
  }

  void _next() {
    if (_index < widget.items.length - 1) setState(() => _index++);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final item = widget.items[_index];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          insetPadding: const EdgeInsets.all(16),
          backgroundColor: const Color(0xFF0D0D0D),
          child: SizedBox(
            width: math.min(1200, size.width - 32),
            height: size.height - 64,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                        child: Text(
                          '${item.name}   ${_index + 1} / ${widget.items.length}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close (Esc)',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                      color: Colors.grey,
                    ),
                  ],
                ),
                Expanded(
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: Center(
                      child: SizedBox.expand(
                        child: FutureBuilder<String?>(
                          future: widget.service.materializeImage(item),
                          builder: (context, snapshot) {
                            final path = snapshot.data;
                            if (path != null) {
                              return Image.file(
                                File(path),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) =>
                                    const _BrokenImage(),
                              );
                            }
                            if (snapshot.connectionState ==
                                ConnectionState.done) {
                              return const _BrokenImage();
                            }
                            return const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Previous (←)',
                        onPressed: _index > 0 ? _prev : null,
                        icon: const Icon(Icons.chevron_left),
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Next (→)',
                        onPressed: _index < widget.items.length - 1
                            ? _next
                            : null,
                        icon: const Icon(Icons.chevron_right),
                        color: Colors.white70,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
