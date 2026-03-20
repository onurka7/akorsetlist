class SetlistItem {
  final int setlistId;
  final int songId;
  final int orderIndex;
  final String? tone;
  final int? durationMinutes;

  SetlistItem({
    required this.setlistId,
    required this.songId,
    required this.orderIndex,
    this.tone,
    this.durationMinutes,
  });

  Map<String, Object?> toMap() => {
        'setlistId': setlistId,
        'songId': songId,
        'orderIndex': orderIndex,
        'tone': tone,
        'durationMinutes': durationMinutes,
      };

  static SetlistItem fromMap(Map<String, Object?> m) => SetlistItem(
        setlistId: m['setlistId'] as int,
        songId: m['songId'] as int,
        orderIndex: m['orderIndex'] as int,
        tone: m['tone'] as String?,
        durationMinutes: m['durationMinutes'] as int?,
      );
}
