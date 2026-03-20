class Setlist {
  final int? id;
  final String name;
  final int createdAt;
  final String? coverPath;

  Setlist({
    this.id,
    required this.name,
    required this.createdAt,
    this.coverPath,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'coverPath': coverPath,
      };

  static Setlist fromMap(Map<String, Object?> m) => Setlist(
        id: m['id'] as int,
        name: m['name'] as String,
        createdAt: m['createdAt'] as int,
        coverPath: m['coverPath'] as String?,
      );
}
