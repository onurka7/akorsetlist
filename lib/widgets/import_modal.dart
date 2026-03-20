import '../services/offline_reader_service.dart';
import '../services/membership_access_service.dart';
import 'package:flutter/material.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';
import '../models/song.dart';
import '../models/setlist.dart';

Future<bool?> showImportModal({
  required BuildContext context,
  required String pageTitle,
  required String pageUrl,
  required String rawHtml,
  required int setlistId,
}) async {
  final setlistRepo = SetlistRepo();
  final songRepo = SongRepo();
  final offlineService = OfflineReaderService();

  final titleCtrl = TextEditingController(text: pageTitle);
  bool offline = true;
  bool favorite = false;

  final setlists = await setlistRepo.listSetlists();
  int? selectedSetlistId;
  for (final s in setlists) {
    if (s.id == setlistId) {
      selectedSetlistId = s.id;
      break;
    }
  }
  selectedSetlistId ??= setlists.isNotEmpty ? setlists.first.id : null;

  if (!context.mounted) return null;

  return await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => StatefulBuilder(
      builder: (modalContext, setModalState) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(modalContext).viewInsets.bottom + 16,
            left: 16,
            right: 16,
            top: 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: "Şarkı adı",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: selectedSetlistId,
                decoration: const InputDecoration(
                  labelText: "Setlist",
                  border: OutlineInputBorder(),
                ),
                items: [
                  if (setlists.isEmpty)
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text("Önce setlist oluştur"),
                    ),
                  ...setlists.map(
                    (Setlist s) => DropdownMenuItem<int?>(
                      value: s.id,
                      child: Text(s.name),
                    ),
                  ),
                ],
                onChanged: (v) {
                  setModalState(() => selectedSetlistId = v);
                },
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: offline,
                onChanged: (v) => setModalState(() => offline = v),
                title: const Text("Offline kaydet (Reader)"),
              ),
              SwitchListTile(
                value: favorite,
                onChanged: (v) => setModalState(() => favorite = v),
                title: const Text("Favorilere ekle"),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: (setlists.isEmpty || selectedSetlistId == null)
                      ? null
                      : () async {
                          final canImport = await MembershipAccessService
                              .instance
                              .canImportSong();
                          if (!canImport) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Free pakette en fazla 5 şarkı eklenebilir. Full üyelik gerekli.',
                                ),
                              ),
                            );
                            return;
                          }

                          final title = titleCtrl.text.trim().isEmpty
                              ? pageTitle
                              : titleCtrl.text.trim();
                          final now = DateTime.now().millisecondsSinceEpoch;

                          final songId = await songRepo.insertSong(
                            Song(
                              title: title,
                              sourceUrl: pageUrl,
                              importedAt: now,
                              offlinePath: null,
                              isFavorite: favorite,
                            ),
                          );

                          if (offline) {
                            final readerHtml =
                                await offlineService.makeReaderHtml(
                              rawHtml,
                              title: title,
                            );

                            final path = await offlineService.saveOfflineHtml(
                              songId: songId,
                              html: readerHtml,
                            );

                            await songRepo.updateSong(
                              Song(
                                id: songId,
                                title: title,
                                sourceUrl: pageUrl,
                                importedAt: now,
                                offlinePath: path,
                                isFavorite: favorite,
                              ),
                            );
                          }

                          await setlistRepo.addSongToSetlist(
                            selectedSetlistId!,
                            songId,
                          );

                          if (!context.mounted) return;
                          Navigator.pop(context, true);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Eklendi: $title")),
                          );
                        },
                  child: const Text("Kaydet"),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    ),
  );
}
