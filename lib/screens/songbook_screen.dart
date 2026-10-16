import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../songbook/songbook.dart';
import 'songbook_song_screen.dart';

const Color _accent = Color(0xFFFFC83D);

/// "Hazır Şarkılar": searchable catalogue of bundled chord sheets
/// (akormatik-style: genre pills with counts, `tag:` search, cover grid).
class SongbookScreen extends StatefulWidget {
  /// Overrides the bundled asset (tests).
  final Future<List<SongbookSong>> Function()? loader;

  const SongbookScreen({super.key, this.loader});

  @override
  State<SongbookScreen> createState() => _SongbookScreenState();
}

Future<List<SongbookSong>> loadBundledSongbook() async => parseSongbook(await rootBundle.loadString(kSongbookAsset));

class _SongbookScreenState extends State<SongbookScreen> {
  final TextEditingController _search = TextEditingController();
  List<SongbookSong>? _songs;
  String? _error;

  @override
  void initState() {
    super.initState();
    (widget.loader ?? loadBundledSongbook)().then((s) {
      if (mounted) setState(() => _songs = s);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim();

  String? get _activeTag {
    final q = songbookLower(_query);
    if (q.isEmpty) return '';
    return q.startsWith('tag:') && !q.contains(' ') ? q.substring(4) : null;
  }

  void _selectTag(String tag) {
    _search.text = tag.isEmpty ? '' : 'tag:${songbookLower(tag)}';
    _search.selection = TextSelection.collapsed(offset: _search.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : const Color(0xFF111827);
    final dim = isDark ? const Color(0xFFB8B8B8) : const Color(0xFF6B7280);
    final fieldBg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final border = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFD8DDE6);
    final songs = _songs;

    return Scaffold(
      appBar: AppBar(title: const Text('Hazır Şarkılar')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Şarkı listesi yüklenemedi: $_error')))
          : songs == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: TextField(
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(tooltip: 'Temizle', icon: const Icon(Icons.close_rounded), onPressed: () => _search.clear()),
                          hintText: 'Şarkı, sanatçı, albüm ya da yazar',
                          filled: true,
                          fillColor: fieldBg,
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        children: [
                          _pill('Tümü', songs.length, '', isDark),
                          for (final (tag, count) in songbookTagCounts(songs)) _pill(tag, count, tag, isDark),
                        ],
                      ),
                    ),
                    Expanded(child: _grid(songs.where((s) => songMatches(s, _query)).toList(), fg, dim)),
                  ],
                ),
    );
  }

  Widget _pill(String label, int count, String tag, bool isDark) {
    final active = _activeTag == songbookLower(tag);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        selected: active,
        showCheckmark: false,
        selectedColor: _accent,
        label: Text('$label  $count', style: TextStyle(fontWeight: FontWeight.w600, color: active ? Colors.black : null)),
        onSelected: (_) => _selectTag(tag),
      ),
    );
  }

  Widget _grid(List<SongbookSong> songs, Color fg, Color dim) {
    if (songs.isEmpty) {
      return Center(child: Text('Aramanızla eşleşen şarkı yok.', style: TextStyle(color: dim, fontStyle: FontStyle.italic)));
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.56,
      ),
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final s = songs[i];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SongbookSongScreen(song: s))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(aspectRatio: 1, child: SongbookCover(song: s)),
              const SizedBox(height: 4),
              // Text block takes the remaining cell height and clips instead
              // of overflowing at large text scales.
              Expanded(
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: fg)),
                      Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: fg)),
                      Text(s.albumLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: dim)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Generated gradient cover with the song title (no artwork is bundled).
class SongbookCover extends StatelessWidget {
  final SongbookSong song;
  final double fontSize;

  const SongbookCover({super.key, required this.song, this.fontSize = 13});

  @override
  Widget build(BuildContext context) {
    final colors = songbookCoverColors(song.id);
    return Container(
      padding: const EdgeInsets.all(7),
      alignment: Alignment.bottomLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
      ),
      child: Text(
        song.title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: fontSize,
          height: 1.05,
          shadows: const [Shadow(blurRadius: 3, color: Colors.black38, offset: Offset(0, 1))],
        ),
      ),
    );
  }
}
