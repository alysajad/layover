import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme.dart';
import '../../companion/data/trip_store.dart';
import '../../companion/domain/models.dart';
import '../data/memory_store.dart';
import '../domain/trip_memory.dart';
import 'memory_camera.dart';

Future<void> openMemories(
  BuildContext context,
  TripStore tripStore, {
  Trip? trip,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => MemoriesScreen(tripStore: tripStore, trip: trip),
  ),
);

class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key, required this.tripStore, this.trip});
  final TripStore tripStore;
  final Trip? trip;
  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  MemoryStore get store => widget.tripStore.memories;
  bool shared = false;
  @override
  void initState() {
    super.initState();
    unawaited(store.refresh());
  }

  Trip? get activeTrip => widget.tripStore.snapshot.trips
      .where((t) => t.id == widget.trip?.id)
      .firstOrNull;
  Future<void> takePhoto() async {
    final trip = activeTrip;
    final owner = store.account;
    if (trip == null || trip.archived) return;
    final capture = await Navigator.of(context).push<MemoryCapture>(
      MaterialPageRoute(builder: (_) => const MemoryCamera()),
    );
    if (!mounted || capture == null || owner != store.account) return;
    final bytes = await capture.file.readAsBytes();
    if (!mounted || owner != store.account) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemoryEditor(
          store: store,
          trip: trip,
          photo: bytes,
          capturedAt: capture.capturedAt,
          canSave: () =>
              activeTrip != null &&
              activeTrip?.archived == false &&
              owner == store.account,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, widget.tripStore]),
    builder: (context, _) {
      final visible =
          store.memories
              .where(
                (m) =>
                    !m.deleted &&
                    (widget.trip == null
                        ? m.owner == store.account
                        : m.tripId == widget.trip!.id &&
                              (shared ? m.shared : m.owner == store.account)),
              )
              .toList()
            ..sort((a, b) {
              if (widget.trip == null && a.tripId != b.tripId) {
                final titleOrder = a.title.compareTo(b.title);
                return titleOrder == 0
                    ? a.tripId.compareTo(b.tripId)
                    : titleOrder;
              }
              return b.capturedAt.compareTo(a.capturedAt);
            });
      final groups = <String, List<TripMemory>>{};
      for (final memory in visible) {
        final day = DateFormat('EEEE, d MMM y').format(memory.capturedAt);
        final key = widget.trip == null
            ? '${memory.title} · ${memory.tripId}'
            : '';
        groups.putIfAbsent('$key\n$day', () => []).add(memory);
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.trip == null ? 'My memories' : 'People I met'),
          actions: [
            IconButton(
              tooltip: 'Retry backup',
              onPressed: store.busy ? null : store.refresh,
              icon: const Icon(Icons.sync),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: store.refresh,
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              if (store.busy) const LinearProgressIndicator(),
              Text(
                widget.trip?.destination ?? 'Faces from your travels',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                widget.trip == null
                    ? 'Your memories stay yours, even after a trip ends.'
                    : 'A face, a name, a little story. Yours to keep.',
                style: const TextStyle(color: LayoverColors.muted),
              ),
              const SizedBox(height: 20),
              if (widget.trip != null) ...[
                if (store.canCapture &&
                    activeTrip != null &&
                    !activeTrip!.archived)
                  FilledButton.icon(
                    onPressed: store.loaded ? takePhoto : null,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Take a photo'),
                  )
                else if (!store.canCapture)
                  const Text(
                    'Take photos in the Android app. Your backed-up memories appear here.',
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Mine'),
                      selected: !shared,
                      onSelected: (_) => setState(() => shared = false),
                    ),
                    ChoiceChip(
                      label: const Text('Shared with trip'),
                      selected: shared,
                      onSelected: (_) => setState(() => shared = true),
                    ),
                  ],
                ),
              ],
              if (store.demo)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Demo photos stay in this session. Sign in for private backup.',
                  ),
                ),
              if (store.error != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(store.error!),
                        TextButton(
                          onPressed: store.busy ? null : store.refresh,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (store.memories.any((m) => m.data['pending'] == 'delete'))
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Deletion waiting for connection. Shared copies remain visible until it finishes.',
                  ),
                ),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 56),
                  child: Column(
                    children: [
                      const Icon(Icons.portrait_outlined, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        shared
                            ? 'No memories shared yet'
                            : 'Remember someone from this trip',
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        shared
                            ? 'Photos appear here when their owner chooses to share.'
                            : 'Take a photo and add their name. Only you can see it.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              for (final group in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 24, bottom: 12),
                  child: Text(
                    widget.trip == null
                        ? '${group.value.first.title}\n${group.key.split('\n').last}'
                        : group.key.trim(),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      for (final m in group.value)
                        SizedBox(
                          width: constraints.maxWidth >= 650
                              ? (constraints.maxWidth - 32) / 3
                              : constraints.maxWidth,
                          child: _MemoryCard(store: store, memory: m),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 36),
            ],
          ),
        ),
      );
    },
  );
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.store, required this.memory});
  final MemoryStore store;
  final TripMemory memory;
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MemoryDetail(store: store, id: memory.id),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: MemoryPhoto(
              key: ValueKey('${store.account}/${memory.id}'),
              store: store,
              memory: memory,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  memory.name.isEmpty ? 'Add name' : memory.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (memory.location.isNotEmpty) Text(memory.location),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Icon(
                      memory.shared ? Icons.group_outlined : Icons.lock_outline,
                      size: 15,
                    ),
                    Text(memory.shared ? 'Shared with trip' : 'Private'),
                    Text(
                      DateFormat('HH:mm').format(memory.capturedAt),
                      style: const TextStyle(color: LayoverColors.muted),
                    ),
                  ],
                ),
                if (memory.owner == store.account)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      memory.pending
                          ? (store.busy ? 'Backing up…' : 'Saved on phone')
                          : memory.ready
                          ? 'Backed up'
                          : 'Photo backup incomplete',
                      style: const TextStyle(
                        fontSize: 12,
                        color: LayoverColors.muted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class MemoryPhoto extends StatefulWidget {
  const MemoryPhoto({super.key, required this.store, required this.memory});
  final MemoryStore store;
  final TripMemory memory;
  @override
  State<MemoryPhoto> createState() => _MemoryPhotoState();
}

class _MemoryPhotoState extends State<MemoryPhoto> with WidgetsBindingObserver {
  Future<Uint8List>? future;
  Uint8List? bytes;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  void load() {
    final epoch = ++generation;
    future = widget.store.photo(widget.memory).then((value) {
      if (mounted && epoch == generation) bytes = value;
      return value;
    });
  }

  void clear() {
    generation++;
    if (bytes != null) MemoryImage(bytes!).evict();
    bytes = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.memory.owner == widget.store.account) return;
    clear();
    if (mounted) {
      setState(() {
        if (state == AppLifecycleState.resumed) {
          load();
        } else {
          future = null;
        }
      });
    }
  }

  @override
  void dispose() {
    clear();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: TextButton.icon(
            onPressed: () => setState(load),
            icon: const Icon(Icons.refresh),
            label: const Text('Load photo'),
          ),
        );
      }
      if (!snapshot.hasData || future == null) {
        return const Center(child: Icon(Icons.portrait_outlined, size: 44));
      }
      return Image.memory(
        snapshot.data!,
        fit: BoxFit.cover,
        semanticLabel: widget.memory.name.isEmpty
            ? 'Trip memory photo'
            : 'Photo of ${widget.memory.name}',
        gaplessPlayback: false,
      );
    },
  );
}

class MemoryDetail extends StatelessWidget {
  const MemoryDetail({super.key, required this.store, required this.id});
  final MemoryStore store;
  final String id;
  Future<void> run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is FormatException
                  ? e.message
                  : 'Could not update this memory. Refresh and try again.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final memory = store.memories
          .where((m) => m.id == id && !m.deleted)
          .firstOrNull;
      if (memory == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Memory')),
          body: const Center(
            child: Text('This memory is no longer available.'),
          ),
        );
      }
      final mine = memory.owner == store.account;
      return Scaffold(
        appBar: AppBar(
          title: Text(memory.name.isEmpty ? 'A face to remember' : memory.name),
        ),
        body: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AspectRatio(
                aspectRatio: 4 / 5,
                child: MemoryPhoto(
                  key: ValueKey('${store.account}/$id'),
                  store: store,
                  memory: memory,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              memory.location,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(DateFormat('d MMM y · HH:mm').format(memory.capturedAt)),
            if (memory.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(memory.note),
              ),
            Text(memory.shared ? 'Shared with trip' : 'Private · only you'),
            if (mine) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: store.busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              MemoryEditor(store: store, memory: memory),
                        ),
                      ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit memory'),
              ),
              FilledButton.icon(
                onPressed:
                    store.busy ||
                        memory.pending ||
                        (!memory.shared && !memory.canShare)
                    ? null
                    : () async {
                        final share = !memory.shared;
                        final accepted = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text(
                              share
                                  ? 'Share with ${memory.title}?'
                                  : 'Make this memory private?',
                            ),
                            content: Text(
                              share
                                  ? 'Trip members will see this photo, name, place, time and note. You can make it private again.'
                                  : 'Trip members will lose access in Layover. This cannot remove screenshots or copies already made.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: Text(
                                  share ? 'Share with trip' : 'Make private',
                                ),
                              ),
                            ],
                          ),
                        );
                        if (accepted == true && context.mounted) {
                          await run(
                            context,
                            () => store.visibility(memory, share),
                          );
                        }
                      },
                icon: Icon(
                  memory.shared ? Icons.lock_outline : Icons.group_outlined,
                ),
                label: Text(memory.shared ? 'Make private' : 'Share with trip'),
              ),
              TextButton(
                onPressed: store.busy
                    ? null
                    : () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Delete this memory?'),
                            content: const Text(
                              'This removes your photo and its backup. Offline deletion finishes when you reconnect.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (yes == true && context.mounted) {
                          await run(context, () => store.delete(memory));
                        }
                      },
                child: const Text('Delete memory'),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class MemoryEditor extends StatefulWidget {
  const MemoryEditor({
    super.key,
    required this.store,
    this.trip,
    this.photo,
    this.capturedAt,
    this.memory,
    this.canSave,
  });
  final MemoryStore store;
  final Trip? trip;
  final Uint8List? photo;
  final DateTime? capturedAt;
  final TripMemory? memory;
  final bool Function()? canSave;
  @override
  State<MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<MemoryEditor> {
  late final name = TextEditingController(text: widget.memory?.name ?? '');
  late final note = TextEditingController(text: widget.memory?.note ?? '');
  late final place = TextEditingController(text: widget.memory?.place ?? '');
  late Uint8List? photo = widget.photo;
  late DateTime? capturedAt = widget.capturedAt;
  late final owner = widget.store.account;
  bool saving = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    note.dispose();
    place.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (owner != widget.store.account) {
        throw const FormatException('Account changed. Reopen this memory.');
      }
      if (widget.memory != null) {
        await widget.store.edit(
          widget.memory!,
          name: name.text,
          note: note.text,
          place: place.text,
        );
      } else {
        if (widget.canSave?.call() == false) {
          throw const FormatException(
            'This trip is no longer active. Keep this screen open and reconnect to check access.',
          );
        }
        await widget.store.save(
          trip: widget.trip!,
          photo: photo!,
          capturedAt: capturedAt!,
          name: name.text,
          note: note.text,
          place: place.text,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : 'Could not save. Keep this screen open and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.memory == null ? 'A face to remember' : 'Edit memory',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          if (photo != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.memory(photo!, fit: BoxFit.cover),
              ),
            ),
            TextButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      final next = await Navigator.of(context)
                          .push<MemoryCapture>(
                            MaterialPageRoute(
                              builder: (_) => const MemoryCamera(),
                            ),
                          );
                      if (next == null || !mounted) return;
                      final bytes = await next.file.readAsBytes();
                      if (mounted) {
                        setState(() {
                          photo = bytes;
                          capturedAt = next.capturedAt;
                        });
                      }
                    },
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Retake'),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: name,
            maxLength: 120,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Their name',
              hintText: 'You can add it later',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.trip?.destination ?? widget.memory?.destination ?? '',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (capturedAt != null)
            Text(DateFormat('d MMM y · HH:mm').format(capturedAt!)),
          const SizedBox(height: 12),
          TextField(
            controller: place,
            maxLength: 240,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Where exactly? (optional)',
              hintText: 'Café near the beach',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            maxLength: 2000,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'A little memory (optional)',
              hintText: 'What would you like to remember?',
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: saving ? null : save,
            icon: Icon(
              widget.memory == null ? Icons.lock_outline : Icons.check,
            ),
            label: Text(
              saving
                  ? 'Saving…'
                  : widget.memory == null
                  ? 'Save privately'
                  : 'Save changes',
            ),
          ),
          if (widget.memory == null)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Only you can see this. You can share with your trip later.',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    ),
  );
}
