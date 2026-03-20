import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:share_plus/share_plus.dart';
import '../models/setlist.dart';
import '../models/setlist_item.dart';
import '../models/song.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';
import '../services/setlist_share_service.dart';
import 'play_screen.dart';

enum _SongSortMode { setlist, alphabetical, popular }

class SetlistDetailScreen extends StatefulWidget {
  final Setlist setlist;
  const SetlistDetailScreen({super.key, required this.setlist});

  @override
  State<SetlistDetailScreen> createState() => _SetlistDetailScreenState();
}

class _SetlistDetailScreenState extends State<SetlistDetailScreen> {
  final repo = SetlistRepo();
  final songRepo = SongRepo();
  final setlistShareService = SetlistShareService();

  List<Song> songs = [];
  Map<int, SetlistItem> _setlistItemsBySongId = {};
  _SongSortMode _sortMode = _SongSortMode.setlist;
  bool _sharing = false;

  void _goHome() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  List<Song> get _visibleSongs {
    final list = List<Song>.from(songs);
    switch (_sortMode) {
      case _SongSortMode.setlist:
        return list;
      case _SongSortMode.alphabetical:
        list.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        return list;
      case _SongSortMode.popular:
        list.sort((a, b) {
          final byCount = b.playCount.compareTo(a.playCount);
          if (byCount != 0) return byCount;
          final byRecent = (b.lastOpenedAt ?? 0).compareTo(a.lastOpenedAt ?? 0);
          if (byRecent != 0) return byRecent;
          final byImported = b.importedAt.compareTo(a.importedAt);
          if (byImported != 0) return byImported;
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
        return list;
    }
  }

  String _songSubtitle(Song s) {
    if (_sortMode != _SongSortMode.popular) return "";
    if (s.playCount <= 0) return "Henüz açılmadı";
    return "${s.playCount} kez açıldı";
  }

  Future<void> _load() async {
    songs = await repo.listSongsInSetlist(widget.setlist.id!);
    final items = await repo.listSetlistItems(widget.setlist.id!);
    _setlistItemsBySongId = {
      for (final item in items) item.songId: item,
    };
    if (!mounted) return;
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _renameSongFromMenu(Song s) async {
    final c = TextEditingController(text: s.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Şarkı adını düzenle"),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("İptal"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Kaydet"),
          ),
        ],
      ),
    );

    final newTitle = c.text.trim();
    if (ok != true || newTitle.isEmpty) return;

    await songRepo.renameSong(s.id!, newTitle);
    await _load();
  }

  Future<void> _removeSongFromSetlist(Song s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Setlist’ten kaldır?"),
        content: Text("“${s.title}” bu setlist’ten çıkarılsın mı?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("Vazgeç"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Kaldır"),
          ),
        ],
      ),
    );

    if (ok != true) return;
    await repo.removeSongFromSetlist(widget.setlist.id!, s.id!);
    songs.removeWhere((x) => x.id == s.id);
    if (mounted) setState(() {});
    await repo.setOrder(widget.setlist.id!, songs.map((e) => e.id!).toList());
  }

  Future<void> _deleteSongEverywhere(Song s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Tamamen sil?"),
        content: Text(
            "“${s.title}” her yerden silinsin mi?\nOffline dosyası da silinir."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("Vazgeç"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Sil"),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final songId = s.id!;
    await repo.removeSongFromAllSetlists(songId);
    final p = s.offlinePath;
    if (p != null && p.isNotEmpty) {
      final f = File(p);
      if (await f.exists()) await f.delete();
    }
    await songRepo.deleteSong(songId);
    songs.removeWhere((x) => x.id == songId);
    if (mounted) setState(() {});
    await repo.setOrder(widget.setlist.id!, songs.map((e) => e.id!).toList());
  }

  Future<void> _onSongMenuSelected(String action, Song s) async {
    switch (action) {
      case 'meta':
        await _editSongMeta(s);
        break;
      case 'rename':
        await _renameSongFromMenu(s);
        break;
      case 'remove':
        await _removeSongFromSetlist(s);
        break;
      case 'delete':
        await _deleteSongEverywhere(s);
        break;
    }
  }

  Future<void> _toggleFavorite(Song s) async {
    if (s.id == null) return;
    await songRepo.setFavorite(s.id!, !s.isFavorite);
    await _load();
  }

  String _setlistMetaSubtitle(Song s) {
    final songId = s.id;
    if (songId == null) return '';
    final meta = _setlistItemsBySongId[songId];
    final parts = <String>[];
    if (meta?.tone != null && meta!.tone!.trim().isNotEmpty) {
      parts.add('Ton: ${meta.tone!.trim()}');
    }
    if (meta?.durationMinutes != null && meta!.durationMinutes! > 0) {
      parts.add('Süre: ${meta.durationMinutes} dk');
    }
    return parts.join(' • ');
  }

  Future<void> _editSongMeta(Song s) async {
    final songId = s.id;
    if (songId == null) return;
    final existing = _setlistItemsBySongId[songId];
    final toneController = TextEditingController(text: existing?.tone ?? '');
    final durationController = TextEditingController(
      text: existing?.durationMinutes?.toString() ?? '',
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Ton ve süre"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: toneController,
              decoration: const InputDecoration(
                labelText: 'Ton',
                hintText: 'Örn: Am, C, F#m',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: durationController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Süre (dakika)',
                hintText: 'Örn: 4',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("İptal"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Kaydet"),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final rawDuration = durationController.text.trim();
    final duration = rawDuration.isEmpty ? null : int.tryParse(rawDuration);
    await repo.updateSetlistItemMeta(
      widget.setlist.id!,
      songId,
      tone: toneController.text.trim(),
      durationMinutes: duration != null && duration > 0 ? duration : null,
    );
    await _load();
  }

  Future<void> _shareSetlist() async {
    if (_sharing) return;
    if (songs.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Boş repertuar paylaşılmaz.')),
      );
      return;
    }

    setState(() => _sharing = true);
    try {
      final payload = await setlistShareService.buildPayload(
        setlist: widget.setlist,
        songs: songs,
        itemMetaBySongId: _setlistItemsBySongId,
      );
      final shareOrigin = _shareOrigin();

      try {
        await Share.shareXFiles(
          [XFile(payload.file.path)],
          text: payload.shareText,
          subject: '${widget.setlist.name} repertuarı',
          sharePositionOrigin: shareOrigin,
        );
      } catch (_) {
        await Share.share(
          '${payload.shareText}\n\nDosya hazırlandı: ${payload.file.path}',
          subject: '${widget.setlist.name} repertuarı',
          sharePositionOrigin: shareOrigin,
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Repertuar paylaşılırken hata oluştu.')),
      );
    } finally {
      if (mounted) {
        setState(() => _sharing = false);
      }
    }
  }

  Rect? _shareOrigin() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Widget _buildSortBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          const Icon(Icons.filter_list, size: 18),
          const SizedBox(width: 8),
          const Text(
            "Sıralama:",
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<_SongSortMode>(
              initialValue: _sortMode,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: const [
                DropdownMenuItem(
                  value: _SongSortMode.setlist,
                  child: Text("Setlist sırası"),
                ),
                DropdownMenuItem(
                  value: _SongSortMode.alphabetical,
                  child: Text("Alfabetik (A-Z)"),
                ),
                DropdownMenuItem(
                  value: _SongSortMode.popular,
                  child: Text("Popüler"),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _sortMode = v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongTile(Song s) {
    final metaSubtitle = _setlistMetaSubtitle(s);
    final subtitle = [
      if (_sortMode == _SongSortMode.popular) _songSubtitle(s),
      if (metaSubtitle.isNotEmpty) metaSubtitle,
    ].where((e) => e.isNotEmpty).join('\n');

    return Slidable(
      key: ValueKey('detail-song-${s.id}'),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.56,
        children: [
          SlidableAction(
            onPressed: (_) => _editSongMeta(s),
            backgroundColor: const Color(0xFF4B5563),
            foregroundColor: Colors.white,
            icon: Icons.schedule_rounded,
            label: 'Ton/Süre',
          ),
          SlidableAction(
            onPressed: (_) => _renameSongFromMenu(s),
            backgroundColor: const Color(0xFFFFC83D),
            foregroundColor: Colors.black,
            icon: Icons.edit,
            label: 'Düzenle',
          ),
          SlidableAction(
            onPressed: (_) => _deleteSongEverywhere(s),
            backgroundColor: const Color(0xFFE74C3C),
            foregroundColor: Colors.white,
            icon: Icons.delete,
            label: 'Sil',
          ),
        ],
      ),
      child: Container(
        key: ValueKey(s.id),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.35),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: ListTile(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: const Color(0xFFFFC83D).withValues(alpha: 0.18),
            child: const Icon(
              Icons.music_note,
              size: 18,
              color: Color(0xFFFFC83D),
            ),
          ),
          title: Text(
            s.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: s.isFavorite ? 'Favoriden çıkar' : 'Favori yap',
                onPressed: () => _toggleFavorite(s),
                icon: Icon(
                  s.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: const Color(0xFFFFC83D),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => _onSongMenuSelected(v, s),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'meta', child: Text("Ton / süre")),
                  PopupMenuItem(
                      value: 'rename', child: Text("Düzenle (Ad değiştir)")),
                  PopupMenuItem(
                      value: 'remove', child: Text("Setlist’ten kaldır")),
                  PopupMenuItem(value: 'delete', child: Text("Tamamen sil")),
                ],
              ),
            ],
          ),
          onTap: () {
            final sourceIndex = songs.indexWhere((x) => x.id == s.id);
            if (sourceIndex < 0) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PlayScreen(
                  setlistId: widget.setlist.id!,
                  initialIndex: sourceIndex,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleSongs = _visibleSongs;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.setlist.name),
        actions: [
          IconButton(
            onPressed: _sharing ? null : _shareSetlist,
            icon: _sharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share_rounded),
            tooltip: 'Repertuarı paylaş',
          ),
          IconButton(
            onPressed: _goHome,
            icon: const Icon(Icons.home_rounded),
            tooltip: 'Ana sayfa',
          ),
        ],
      ),
      body: songs.isEmpty
          ? const Center(
              child: Text("Bu setlist boş. Ara sekmesinden Import yap."))
          : Column(
              children: [
                _buildSortBar(),
                if (_sortMode == _SongSortMode.popular)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Popüler sıralama açılma sayısına göre yapılır.",
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                Expanded(
                  child: _sortMode == _SongSortMode.setlist
                      ? ReorderableListView.builder(
                          itemCount: songs.length,
                          onReorder: (oldIndex, newIndex) async {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final item = songs.removeAt(oldIndex);
                            songs.insert(newIndex, item);
                            setState(() {});
                            await repo.setOrder(
                              widget.setlist.id!,
                              songs.map((e) => e.id!).toList(),
                            );
                          },
                          itemBuilder: (context, i) => _buildSongTile(songs[i]),
                        )
                      : ListView.builder(
                          itemCount: visibleSongs.length,
                          itemBuilder: (context, i) =>
                              _buildSongTile(visibleSongs[i]),
                        ),
                ),
              ],
            ),
    );
  }
}
