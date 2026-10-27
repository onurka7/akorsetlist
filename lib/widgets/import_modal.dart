import 'dart:convert';

import '../services/offline_reader_service.dart';
import '../services/membership_access_service.dart';
import 'package:flutter/material.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';
import '../models/song.dart';
import '../models/setlist.dart';
import '../services/timed_chord_sheet_service.dart';

Future<bool?> showImportModal({
  required BuildContext context,
  required String pageTitle,
  required String pageUrl,
  required String rawHtml,
  required int setlistId,
  Song? existingSong,
}) async {
  final setlistRepo = SetlistRepo();
  final songRepo = SongRepo();
  final offlineService = OfflineReaderService();
  final timedChordSheetService = TimedChordSheetService();

  final titleCtrl = TextEditingController(text: pageTitle);
  bool offline = true;
  bool favorite = false;
  bool saving = false;

  final setlists = await setlistRepo.listSetlists();
  int? selectedSetlistId;
  final targetSong = existingSong;
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
                  onPressed: (setlists.isEmpty ||
                          selectedSetlistId == null ||
                          saving)
                      ? null
                      : () async {
                          setModalState(() => saving = true);
                          final canImport = await MembershipAccessService
                              .instance
                              .canImportSong();
                          if (!canImport) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Free planda en fazla 5 sarki eklenebilir. Yillik plan gerekli.',
                                ),
                              ),
                            );
                            if (modalContext.mounted) {
                              setModalState(() => saving = false);
                            }
                            return;
                          }

                          final title = titleCtrl.text.trim().isEmpty
                              ? pageTitle
                              : titleCtrl.text.trim();
                          final now = DateTime.now().millisecondsSinceEpoch;
                          final foundExistingSong = targetSong ??
                              await songRepo.findByTitleAndSourceUrl(
                            title,
                            pageUrl,
                          );
                          final timedChordSheet =
                              timedChordSheetService.buildFromHtml(rawHtml);
                          final readerHtml = timedChordSheet == null
                              ? await offlineService.makeReaderHtml(
                                  rawHtml,
                                  title: title,
                                )
                              : timedChordSheetService.buildReaderHtml(
                                  sheet: timedChordSheet,
                                  title: title,
                                );
                          final timedChordSheetJson = timedChordSheet == null
                              ? null
                              : jsonEncode(timedChordSheet.toMap());
                          final songId = foundExistingSong?.id ??
                              await songRepo.insertSong(
                                Song(
                                  title: title,
                                  sourceUrl: pageUrl,
                                  importedAt: now,
                                  offlinePath: null,
                                  audioPath: null,
                                  isFavorite: favorite,
                                  timedChordSheetJson: timedChordSheetJson,
                                ),
                              );
                          // Audio is attached later from the setlist; keep any existing link.
                          final persistedAudioPath = foundExistingSong?.audioPath;

                          String? offlinePath = foundExistingSong?.offlinePath;
                          if (offline) {
                            offlinePath = await offlineService.saveOfflineHtml(
                              songId: songId,
                              html: readerHtml,
                            );
                          }

                          await songRepo.updateSong(
                            Song(
                              id: songId,
                              title: title,
                              sourceUrl: pageUrl,
                              importedAt: foundExistingSong?.importedAt ?? now,
                              lastOpenedAt: foundExistingSong?.lastOpenedAt,
                              playCount: foundExistingSong?.playCount ?? 0,
                              offlinePath: offlinePath,
                              audioPath: persistedAudioPath,
                              isFavorite:
                                  (foundExistingSong?.isFavorite ?? false) ||
                                  favorite,
                              timedChordSheetJson: timedChordSheetJson ??
                                  foundExistingSong?.timedChordSheetJson,
                            ),
                          );

                          await setlistRepo.addSongToSetlist(
                            selectedSetlistId!,
                            songId,
                          );

                          if (!modalContext.mounted) return;
                          final messenger = ScaffoldMessenger.of(context);
                          Navigator.of(modalContext).pop(true);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                foundExistingSong == null
                                    ? "Eklendi: $title"
                                    : "Guncellendi: $title",
                              ),
                            ),
                          );
                        },
                  child: Text(saving ? "Kaydediliyor..." : "Kaydet"),
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
