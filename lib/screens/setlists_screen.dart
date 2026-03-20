import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../models/setlist.dart';
import '../models/song.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';
import '../services/membership_access_service.dart';
import '../services/user_storage_service.dart';
import '../widgets/google_auth_widget.dart';
import 'play_screen.dart';
import 'setlist_detail_screen.dart';

class SetlistsScreen extends StatefulWidget {
  final ValueNotifier<int> refresh;
  final ValueNotifier<int>? createRequest;
  final bool isDarkMode;
  final ValueChanged<bool>? onThemeChanged;
  final ValueChanged<int?>? onActiveSetlistChanged;
  final ValueChanged<String>? onQuickAction;

  const SetlistsScreen({
    super.key,
    required this.refresh,
    this.createRequest,
    this.isDarkMode = true,
    this.onThemeChanged,
    this.onActiveSetlistChanged,
    this.onQuickAction,
  });

  @override
  State<SetlistsScreen> createState() => SetlistsScreenState();
}

class SetlistsScreenState extends State<SetlistsScreen> {
  final repo = SetlistRepo();
  final songRepo = SongRepo();

  List<Setlist> setlists = [];
  List<Song> allSongs = [];
  List<Song> favoriteSongs = [];
  final Map<int, int> _songCounts = {};
  bool loading = true;

  int? _lastEmittedSetlistId;
  int _topTab = -1; // -1: home, 0: songs, 1: setlists, 2: favorites

  int get currentTopTab => _topTab;

  void showDashboardHome() {
    if (!mounted) return;
    setState(() => _topTab = -1);
  }

  void showAllSongs() {
    if (!mounted) return;
    setState(() => _topTab = 0);
  }

  @override
  void initState() {
    super.initState();
    _load();
    widget.refresh.addListener(_onRefresh);
    widget.createRequest?.addListener(_onCreateRequest);
  }

  @override
  void didUpdateWidget(covariant SetlistsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refresh != widget.refresh) {
      oldWidget.refresh.removeListener(_onRefresh);
      widget.refresh.addListener(_onRefresh);
    }
    if (oldWidget.createRequest != widget.createRequest) {
      oldWidget.createRequest?.removeListener(_onCreateRequest);
      widget.createRequest?.addListener(_onCreateRequest);
    }
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_onRefresh);
    widget.createRequest?.removeListener(_onCreateRequest);
    super.dispose();
  }

  void _onRefresh() => _load();

  void _onCreateRequest() {
    _createSetlist();
  }

  void _emitActiveSetlistId(int? setlistId) {
    if (_lastEmittedSetlistId == setlistId) return;
    _lastEmittedSetlistId = setlistId;
    widget.onActiveSetlistChanged?.call(setlistId);
  }

  Future<void> _load() async {
    setState(() => loading = true);

    final items = await repo.listSetlists();
    final loadedSongs = await songRepo.listAllSongs();
    final loadedFavorites = loadedSongs.where((s) => s.isFavorite).toList();
    final entries = await Future.wait(
      items.where((s) => s.id != null).map(
            (s) async => MapEntry(s.id!, await repo.countSongsInSetlist(s.id!)),
          ),
    );

    if (!mounted) return;
    setState(() {
      setlists = items;
      allSongs = loadedSongs;
      favoriteSongs = loadedFavorites;
      _songCounts
        ..clear()
        ..addAll({for (final e in entries) e.key: e.value});
      loading = false;
    });

    int? firstSetlistId;
    for (final s in items) {
      if (s.id != null) {
        firstSetlistId = s.id;
        break;
      }
    }
    _emitActiveSetlistId(firstSetlistId);
  }

  Future<void> _createSetlist() async {
    final canCreate = await MembershipAccessService.instance.canCreateSetlist();
    if (!mounted) return;
    if (!canCreate) {
      _showMessage(
        'Free pakette en fazla 1 setlist oluşturabilirsin. Full üyelik gerekli.',
      );
      return;
    }

    final controller = TextEditingController();
    final picker = ImagePicker();
    String? pickedCoverPath;

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('Yeni Setlist'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () async {
                  final x = await picker.pickImage(
                    source: ImageSource.gallery,
                    imageQuality: 85,
                  );
                  if (x == null) return;
                  setModalState(() => pickedCoverPath = x.path);
                },
                child: SizedBox(
                  height: 120,
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (pickedCoverPath == null)
                          Image.network(
                            _SetlistCoverImage.defaultGuitarImageUrl,
                            fit: BoxFit.cover,
                          )
                        else
                          Image.file(File(pickedCoverPath!), fit: BoxFit.cover),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.12),
                                Colors.black.withValues(alpha: 0.48),
                              ],
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.35),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.upload_rounded,
                                    size: 16, color: Colors.white),
                                SizedBox(width: 6),
                                Text(
                                  'Kapak seç / değiştir',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Setlist adı',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) =>
                    Navigator.pop(dialogContext, value.trim()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('İptal'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Oluştur'),
            ),
          ],
        ),
      ),
    );

    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;

    String? storedCoverPath;
    if (pickedCoverPath != null && pickedCoverPath!.isNotEmpty) {
      final coversDir = await UserStorageService.coversDirectory();
      final ext = p.extension(pickedCoverPath!);
      final filename = 'cover_${DateTime.now().millisecondsSinceEpoch}$ext';
      final target = p.join(coversDir.path, filename);
      storedCoverPath = (await File(pickedCoverPath!).copy(target)).path;
    }

    final uniqueName = await repo.nextAvailableSetlistName(trimmed);
    await repo.createSetlist(uniqueName, coverPath: storedCoverPath);
    await _load();
  }

  Future<void> _renameSetlist(Setlist s) async {
    final controller = TextEditingController(text: s.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Setlist adını düzenle'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Setlist adı',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );

    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == s.name) return;
    final uniqueName = await repo.nextAvailableSetlistName(trimmed);
    await repo.renameSetlist(s.id!, uniqueName);
    await _load();
  }

  Future<void> _deleteSetlist(Setlist s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Setlist silinsin mi?'),
        content: Text('“${s.name}” silinecek. Emin misin?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    await repo.deleteSetlist(s.id!);
    await _load();
  }

  Future<void> _openSongFromSearch(Song song) async {
    final songId = song.id;
    if (songId == null) return;

    final setlist = await repo.firstSetlistForSong(songId);
    if (setlist == null || setlist.id == null) {
      if (!mounted) return;
      _showMessage('Bu şarkı bir setlist içinde bulunamadı.');
      return;
    }

    _emitActiveSetlistId(setlist.id);

    final songs = await repo.listSongsInSetlist(setlist.id!);
    final index = songs.indexWhere((s) => s.id == songId);
    if (index < 0 || !mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayScreen(setlistId: setlist.id!, initialIndex: index),
      ),
    );
    await _load();
  }

  Future<void> _toggleFavorite(Song song) async {
    final songId = song.id;
    if (songId == null) return;
    await songRepo.setFavorite(songId, !song.isFavorite);
    await _load();
  }

  Future<void> _renameSong(Song song) async {
    final songId = song.id;
    if (songId == null) return;
    final controller = TextEditingController(text: song.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Şarkı adını düzenle'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Şarkı adı',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );

    final newTitle = controller.text.trim();
    if (ok != true || newTitle.isEmpty) return;
    await songRepo.renameSong(songId, newTitle);
    await _load();
  }

  Future<void> _deleteSong(Song song) async {
    final songId = song.id;
    if (songId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Şarkı tamamen silinsin mi?'),
        content: Text(
          '“${song.title}” tüm repertuarlardan kaldırılacak ve cihazdan silinecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final offlinePath = song.offlinePath;
    if (offlinePath != null && offlinePath.isNotEmpty) {
      final file = File(offlinePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
    await repo.removeSongFromAllSetlists(songId);
    await songRepo.deleteSong(songId);
    await _load();
  }

  Future<void> _openSongsSearch() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        List<Song> results = [];
        bool loadingSongs = true;
        bool initialized = false;

        Future<void> runSearch(StateSetter setModal, String q) async {
          setModal(() => loadingSongs = true);
          final items = await songRepo.searchSongsByTitle(q);
          if (!sheetContext.mounted) return;
          setModal(() {
            results = items;
            loadingSongs = false;
          });
        }

        return StatefulBuilder(
          builder: (ctx, setModal) {
            if (!initialized) {
              initialized = true;
              runSearch(setModal, '');
            }
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Kayıtlı şarkılarda ara',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) => runSearch(setModal, v),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: loadingSongs
                          ? const Center(child: CircularProgressIndicator())
                          : results.isEmpty
                              ? const Center(child: Text('Şarkı bulunamadı'))
                              : ListView.separated(
                                  itemCount: results.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (_, i) {
                                    final s = results[i];
                                    final host =
                                        Uri.tryParse(s.sourceUrl)?.host;
                                    return ListTile(
                                      title: Text(
                                        s.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        host == null || host.isEmpty
                                            ? 'Kayıtlı şarkı'
                                            : host,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onTap: () async {
                                        Navigator.pop(sheetContext);
                                        await _openSongFromSearch(s);
                                      },
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildQuickCards(bool isDark) {
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFD8DDE6);

    Widget card({
      required IconData icon,
      required String title,
      required String imageUrl,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          height: 86,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: isDark
                        ? const Color(0xFF1E1E1E)
                        : const Color(0xFF334155),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.70),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Row(
                    children: [
                      Icon(icon, color: const Color(0xFFFFC83D), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Colors.white70),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        card(
          icon: Icons.queue_music_rounded,
          title: 'Setlerim',
          imageUrl:
              'https://images.unsplash.com/photo-1510915361894-db8b60106cb1?auto=format&fit=crop&w=900&q=80',
          onTap: () => setState(() => _topTab = 1),
        ),
        const SizedBox(height: 10),
        card(
          icon: Icons.library_music_rounded,
          title: 'Tüm Şarkılar',
          imageUrl:
              'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?auto=format&fit=crop&w=900&q=80',
          onTap: () => setState(() => _topTab = 0),
        ),
        const SizedBox(height: 10),
        card(
          icon: Icons.favorite_rounded,
          title: 'Favoriler',
          imageUrl:
              'https://images.unsplash.com/photo-1516280440614-37939bbacd81?auto=format&fit=crop&w=900&q=80',
          onTap: () => setState(() => _topTab = 2),
        ),
        const SizedBox(height: 10),
        card(
          icon: Icons.music_note_rounded,
          title: 'Akorlar',
          imageUrl:
              'https://images.unsplash.com/photo-1525201548942-d8732f6617a0?auto=format&fit=crop&w=900&q=80',
          onTap: () => widget.onQuickAction?.call('chords'),
        ),
        const SizedBox(height: 10),
        card(
          icon: Icons.tune_rounded,
          title: 'Akort Yapma',
          imageUrl:
              'https://images.unsplash.com/photo-1511379938547-c1f69419868d?auto=format&fit=crop&w=900&q=80',
          onTap: () => widget.onQuickAction?.call('tuner'),
        ),
        const SizedBox(height: 10),
        card(
          icon: Icons.hearing_rounded,
          title: 'Akort Çıkarma',
          imageUrl:
              'https://images.unsplash.com/photo-1464375117522-1311d6a5b81f?auto=format&fit=crop&w=900&q=80',
          onTap: () => widget.onQuickAction?.call('chord_detection'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final filtered = setlists;
    final bgStart = isDark ? const Color(0xFF000000) : const Color(0xFFF4F6FA);
    final bgEnd = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFE7ECF3);
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final textDim = isDark ? const Color(0xFFE1D0A2) : const Color(0xFF6B7280);

    final inSection = _topTab != -1;
    final sectionTitle = _topTab == 0
        ? 'Tüm Şarkılar'
        : _topTab == 1
            ? 'Setlerim'
            : _topTab == 2
                ? 'Favoriler'
                : 'Repertuarım';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgStart, bgEnd],
          ),
        ),
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              sectionTitle,
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (!inSection || _topTab == 0)
                            IconButton(
                              onPressed: _openSongsSearch,
                              icon: const Icon(
                                Icons.search,
                                color: Color(0xFFFFC83D),
                              ),
                            ),
                          if (!inSection || _topTab == 1) ...[
                            const SizedBox(width: 2),
                            GestureDetector(
                              onTap: _createSetlist,
                              child: Container(
                                width: 46,
                                height: 46,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFFFC83D),
                                  shape: BoxShape.circle,
                                ),
                                child:
                                    const Icon(Icons.add, color: Colors.black),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (!inSection)
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
                          children: [
                            GoogleAuthWidget(
                              mode: GoogleAuthMode.banner,
                              isDark: isDark,
                              onMessage: _showMessage,
                            ),
                            const SizedBox(height: 8),
                            _buildQuickCards(isDark),
                          ],
                        ),
                      ),
                    if (inSection)
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                          children: [
                            if (_topTab == 0) ...[
                              if (allSongs.isEmpty)
                                Center(
                                  child: Text(
                                    'Henüz şarkı yok',
                                    style: TextStyle(color: textDim),
                                  ),
                                ),
                              ...allSongs.map((song) => _SongTile(
                                    song: song,
                                    isDark: isDark,
                                    onToggleFavorite: () =>
                                        _toggleFavorite(song),
                                    onRename: () => _renameSong(song),
                                    onDelete: () => _deleteSong(song),
                                    onTap: () => _openSongFromSearch(song),
                                  )),
                            ],
                            if (_topTab == 1) ...[
                              ...filtered.map((s) => Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Slidable(
                                      key: ValueKey('setlist-${s.id}'),
                                      endActionPane: ActionPane(
                                        motion: const DrawerMotion(),
                                        extentRatio: 0.45,
                                        children: [
                                          SlidableAction(
                                            onPressed: (_) => _renameSetlist(s),
                                            backgroundColor:
                                                const Color(0xFFFFC83D),
                                            foregroundColor: Colors.black,
                                            icon: Icons.edit,
                                            label: 'Düzenle',
                                          ),
                                          SlidableAction(
                                            onPressed: (_) => _deleteSetlist(s),
                                            backgroundColor:
                                                const Color(0xFFE74C3C),
                                            foregroundColor: Colors.white,
                                            icon: Icons.delete,
                                            label: 'Sil',
                                          ),
                                        ],
                                      ),
                                      child: _SetlistListTile(
                                        coverPath: s.coverPath,
                                        title: s.name,
                                        subtitle:
                                            '${_songCounts[s.id] ?? 0} şarkı • güncel',
                                        isDark: isDark,
                                        onTap: () {
                                          _emitActiveSetlistId(s.id);
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  SetlistDetailScreen(
                                                      setlist: s),
                                            ),
                                          ).then((_) => _load());
                                        },
                                      ),
                                    ),
                                  )),
                              if (filtered.isEmpty)
                                Center(
                                  child: Text(
                                    'Setlist bulunamadı',
                                    style: TextStyle(color: textDim),
                                  ),
                                ),
                            ],
                            if (_topTab == 2) ...[
                              if (favoriteSongs.isEmpty)
                                Center(
                                  child: Text(
                                    'Favori şarkı yok',
                                    style: TextStyle(color: textDim),
                                  ),
                                ),
                              ...favoriteSongs.map((song) => _SongTile(
                                    song: song,
                                    isDark: isDark,
                                    onToggleFavorite: () =>
                                        _toggleFavorite(song),
                                    onRename: () => _renameSong(song),
                                    onDelete: () => _deleteSong(song),
                                    onTap: () => _openSongFromSearch(song),
                                  )),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _SongTile extends StatelessWidget {
  final Song song;
  final bool isDark;
  final VoidCallback onToggleFavorite;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  const _SongTile({
    required this.song,
    required this.isDark,
    required this.onToggleFavorite,
    required this.onRename,
    required this.onDelete,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cardColor =
        isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFFFF);
    final borderColor =
        isDark ? const Color(0xFF2C2C2C) : const Color(0xFFD8DDE6);
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);

    return Slidable(
      key: ValueKey('song-${song.id}'),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.42,
        children: [
          SlidableAction(
            onPressed: (_) => onRename(),
            backgroundColor: const Color(0xFFFFC83D),
            foregroundColor: Colors.black,
            icon: Icons.edit,
            label: 'Düzenle',
          ),
          SlidableAction(
            onPressed: (_) => onDelete(),
            backgroundColor: const Color(0xFFE74C3C),
            foregroundColor: Colors.white,
            icon: Icons.delete,
            label: 'Sil',
          ),
        ],
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          leading: CircleAvatar(
            backgroundColor:
                isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF1F5F9),
            child: const Icon(Icons.music_note, color: Color(0xFFFFC83D)),
          ),
          title: Text(
            song.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: titleColor, fontWeight: FontWeight.w700),
          ),
          trailing: IconButton(
            tooltip: song.isFavorite ? 'Favoriden çıkar' : 'Favori yap',
            onPressed: onToggleFavorite,
            icon: Icon(
              song.isFavorite ? Icons.favorite : Icons.favorite_border,
              color: const Color(0xFFFFC83D),
            ),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _SetlistCoverImage extends StatelessWidget {
  static const String defaultGuitarImageUrl =
      'https://images.unsplash.com/photo-1510915361894-db8b60106cb1?auto=format&fit=crop&w=1200&q=80';

  final String? coverPath;
  final Color fallback;

  const _SetlistCoverImage({this.coverPath, required this.fallback});

  @override
  Widget build(BuildContext context) {
    if (coverPath != null && coverPath!.isNotEmpty) {
      final f = File(coverPath!);
      if (f.existsSync()) {
        return Image.file(f, fit: BoxFit.cover);
      }
    }

    return Image.network(
      defaultGuitarImageUrl,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              fallback.withValues(alpha: 0.95),
              fallback.withValues(alpha: 0.7),
            ],
          ),
        ),
        child: const Icon(Icons.music_note, color: Color(0xFFFFC83D)),
      ),
    );
  }
}

class _SetlistListTile extends StatelessWidget {
  final String? coverPath;
  final String title;
  final String subtitle;
  final bool isDark;
  final VoidCallback onTap;

  const _SetlistListTile({
    required this.coverPath,
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cardColor =
        isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFFFF);
    final borderColor =
        isDark ? const Color(0xFF2C2C2C) : const Color(0xFFD8DDE6);
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final subColor = isDark ? const Color(0xFFE1D0A2) : const Color(0xFF6B7280);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(15)),
              child: SizedBox(
                width: 92,
                height: 92,
                child: _SetlistCoverImage(
                  coverPath: coverPath,
                  fallback: isDark
                      ? const Color(0xFF1F2937)
                      : const Color(0xFFCBD5E1),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: subColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: Icon(Icons.chevron_right, color: Color(0xFFFFC83D)),
            ),
          ],
        ),
      ),
    );
  }
}
