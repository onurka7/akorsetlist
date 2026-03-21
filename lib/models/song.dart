class Song {
  final int? id;
  final String title;
  final String sourceUrl;
  final int importedAt;
  final int? lastOpenedAt;
  final int playCount;
  final String? offlinePath;
  final String? audioPath;
  final bool isFavorite;
  final String? timedChordSheetJson;

  Song({
    this.id,
    required this.title,
    required this.sourceUrl,
    required this.importedAt,
    this.lastOpenedAt,
    this.playCount = 0,
    this.offlinePath,
    this.audioPath,
    this.isFavorite = false,
    this.timedChordSheetJson,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'sourceUrl': sourceUrl,
        'importedAt': importedAt,
        'lastOpenedAt': lastOpenedAt,
        'playCount': playCount,
        'offlinePath': offlinePath,
        'audioPath': audioPath,
        'isFavorite': isFavorite ? 1 : 0,
        'timedChordSheetJson': timedChordSheetJson,
      };

  static Song fromMap(Map<String, Object?> m) => Song(
        id: m['id'] as int,
        title: m['title'] as String,
        sourceUrl: m['sourceUrl'] as String,
        importedAt: m['importedAt'] as int,
        lastOpenedAt: m['lastOpenedAt'] as int?,
        playCount: (m['playCount'] as int?) ?? 0,
        offlinePath: m['offlinePath'] as String?,
        audioPath: m['audioPath'] as String?,
        isFavorite: ((m['isFavorite'] as int?) ?? 0) == 1,
        timedChordSheetJson: m['timedChordSheetJson'] as String?,
      );
}
