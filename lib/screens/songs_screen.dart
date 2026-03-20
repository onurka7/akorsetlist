import 'package:flutter/material.dart';

import '../models/song.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';
import 'play_screen.dart';

class SongsScreen extends StatefulWidget {
  final bool isDarkMode;

  const SongsScreen({
    super.key,
    required this.isDarkMode,
  });

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  final SongRepo _songRepo = SongRepo();
  final SetlistRepo _setlistRepo = SetlistRepo();
  final TextEditingController _searchController = TextEditingController();

  List<Song> _songs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSongs();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {});
  }

  Future<void> _loadSongs() async {
    setState(() => _loading = true);
    final items = await _songRepo.listAllSongs();
    if (!mounted) return;
    setState(() {
      _songs = items;
      _loading = false;
    });
  }

  Future<void> _toggleFavorite(Song song) async {
    final songId = song.id;
    if (songId == null) return;
    await _songRepo.setFavorite(songId, !song.isFavorite);
    await _loadSongs();
  }

  Future<void> _openSong(Song song) async {
    final songId = song.id;
    if (songId == null) return;

    final setlist = await _setlistRepo.firstSetlistForSong(songId);
    if (setlist == null || setlist.id == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Bu şarkı bir setlist içinde bulunamadı.')),
      );
      return;
    }

    final songs = await _setlistRepo.listSongsInSetlist(setlist.id!);
    final index = songs.indexWhere((s) => s.id == songId);
    if (index < 0 || !mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayScreen(setlistId: setlist.id!, initialIndex: index),
      ),
    );
    await _loadSongs();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final bgA = isDark ? const Color(0xFF000000) : const Color(0xFFF4F6FA);
    final bgB = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFE7ECF3);
    final searchBg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final border = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFD8DDE6);

    final q = _searchController.text.trim().toLowerCase();
    final visible = q.isEmpty
        ? _songs
        : _songs.where((s) => s.title.toLowerCase().contains(q)).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgA, bgB],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Şarkılar',
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Yenile',
                            onPressed: _loadSongs,
                            icon: const Icon(
                              Icons.refresh,
                              color: Color(0xFFFFC83D),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: 'İndirilen şarkılarda ara',
                          filled: true,
                          fillColor: searchBg,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: border),
                          ),
                          prefixIcon: const Icon(Icons.search),
                          isDense: true,
                        ),
                      ),
                    ),
                    Expanded(
                      child: visible.isEmpty
                          ? const Center(child: Text('İndirilen şarkı yok'))
                          : ListView.separated(
                              padding:
                                  const EdgeInsets.fromLTRB(14, 2, 14, 110),
                              itemCount: visible.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, i) {
                                final song = visible[i];
                                return Material(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(12),
                                  child: ListTile(
                                    onTap: () => _openSong(song),
                                    leading:
                                        const Icon(Icons.music_note_rounded),
                                    title: Text(
                                      song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      (Uri.tryParse(song.sourceUrl)?.host ?? '')
                                          .replaceFirst('www.', ''),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: IconButton(
                                      tooltip: song.isFavorite
                                          ? 'Favoriden çıkar'
                                          : 'Favori yap',
                                      onPressed: () => _toggleFavorite(song),
                                      icon: Icon(
                                        song.isFavorite
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        color: const Color(0xFFFFC83D),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
