import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../db/app_db.dart';
import '../models/membership_plan.dart';
import '../services/backup_service.dart';
import '../screens/plan_selection_screen.dart';
import '../services/setlist_import_service.dart';
import '../state/auth_state.dart';
import '../state/membership_state.dart';
import '../state/ui_prefs.dart';
import '../services/user_storage_service.dart';
import '../widgets/google_auth_widget.dart';

class SettingsScreen extends StatefulWidget {
  final bool isDarkMode;
  final ValueChanged<bool>? onThemeChanged;

  const SettingsScreen({
    super.key,
    required this.isDarkMode,
    this.onThemeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _deleteBusy = false;
  final backupService = BackupService();
  final setlistImportService = SetlistImportService();

  Future<void> _pickChordColor(BuildContext context) async {
    final colors = <Color>[
      const Color(0xFFB00020),
      const Color(0xFFEF5350),
      const Color(0xFF66BB6A),
      const Color(0xFF42A5F5),
      const Color(0xFFFFC83D),
    ];

    final selected = await showModalBottomSheet<Color>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        child: ValueListenableBuilder<Color>(
          valueListenable: UiPrefs.chordColor,
          builder: (_, active, __) {
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: colors
                  .map(
                    (c) => GestureDetector(
                      onTap: () => Navigator.pop(ctx, c),
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: c,
                        child: active == c
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 18)
                            : null,
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ),
    );

    if (selected != null) {
      await UiPrefs.setChordColor(selected);
      if (!mounted) return;
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text('Akor rengi güncellendi.')),
      );
    }
  }

  Future<void> _exportBackup() async {
    try {
      final file = await backupService.exportToJsonFile();
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Akor Setlist Yedeği',
        text: 'Yedek dosyası',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yedek dışa aktarılamadı: $e')),
      );
    }
  }

  Future<void> _importBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: false,
    );
    final path = (picked == null || picked.files.isEmpty)
        ? null
        : picked.files.first.path;
    if (path == null || path.isEmpty || !mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Yedek geri yüklensin mi?'),
        content: const Text(
          'Mevcut setlist ve şarkılar yedek içeriği ile değiştirilecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Geri Yükle'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await backupService.restoreFromJsonFile(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Yedek başarıyla geri yüklendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yedek geri yüklenemedi: $e')),
      );
    }
  }

  Future<void> _importSharedSetlist() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['akorsetlist', 'json'],
      withData: false,
    );
    final path = (picked == null || picked.files.isEmpty)
        ? null
        : picked.files.first.path;
    if (path == null || path.isEmpty || !mounted) return;

    try {
      final importedName = await setlistImportService.importSharedSetlist(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$importedName repertuarı içe aktarıldı.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Repertuar içe aktarılamadı: $e')),
      );
    }
  }

  Future<void> _deleteAccountAndLocalData() async {
    if (_deleteBusy) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hesap ve Veriler Silinsin mi?'),
        content: const Text(
          'Bu işlem bu cihazdaki tüm setlist, şarkı ve hesap oturumunu siler. Geri alınamaz.',
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

    setState(() => _deleteBusy = true);
    try {
      await AppDb.instance.deleteCurrentUserDatabase();
      await UserStorageService.deleteCurrentUserStorage();
      MembershipState.instance.disableDemoMode();
      await AuthState.instance.signOut();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hesap ve cihaz verileri silindi.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Silme işlemi başarısız: $e')),
      );
    } finally {
      if (mounted) setState(() => _deleteBusy = false);
    }
  }

  Future<void> _openPlanScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlanSelectionScreen(
          isDarkMode: widget.isDarkMode,
          allowClose: true,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final bgA = isDark ? const Color(0xFF000000) : const Color(0xFFF4F6FA);
    final bgB = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFE7ECF3);
    final cardBg = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFFFF);
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFD8DDE6);
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final subtitleColor =
        isDark ? const Color(0xFFE1D0A2) : const Color(0xFF6B7280);
    final activePlan = MembershipState.instance.currentPlan.value;
    final planTitle = activePlan == null ? 'Plan yukleniyor' : activePlan.title;
    final planSubtitle = activePlan == MembershipPlan.annual
        ? 'Tum premium ozellikler acik'
        : '5 sarki, 1 setlist ve sinirli erisim';

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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              Text(
                'Ayarlar',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: SwitchListTile(
                  value: widget.isDarkMode,
                  title: Text(
                    'Tema',
                    style: TextStyle(color: titleColor),
                  ),
                  subtitle: Text(
                    widget.isDarkMode ? 'Koyu tema açık' : 'Açık tema açık',
                    style: TextStyle(color: subtitleColor),
                  ),
                  activeThumbColor: const Color(0xFFFFC83D),
                  onChanged: (v) => widget.onThemeChanged?.call(v),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: ListTile(
                  leading: const Icon(Icons.workspace_premium_rounded),
                  title: Text(
                    planTitle,
                    style: TextStyle(color: titleColor),
                  ),
                  subtitle: Text(
                    planSubtitle,
                    style: TextStyle(color: subtitleColor),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Color(0xFFFFC83D),
                  ),
                  onTap: _openPlanScreen,
                ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<Color>(
                valueListenable: UiPrefs.chordColor,
                builder: (_, chordColor, __) {
                  return Container(
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: borderColor),
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: chordColor,
                        child:
                            const Icon(Icons.music_note, color: Colors.black),
                      ),
                      title: Text(
                        'Akor rengi',
                        style: TextStyle(color: titleColor),
                      ),
                      subtitle: Text(
                        'Çalma ekranındaki akor rengi',
                        style: TextStyle(color: subtitleColor),
                      ),
                      trailing: const Icon(Icons.chevron_right,
                          color: Color(0xFFFFC83D)),
                      onTap: () => _pickChordColor(context),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.ios_share_outlined),
                      title: Text(
                        'Yedeği dışa aktar',
                        style: TextStyle(color: titleColor),
                      ),
                      subtitle: Text(
                        'Setlist ve şarkıları JSON olarak paylaş',
                        style: TextStyle(color: subtitleColor),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Color(0xFFFFC83D),
                      ),
                      onTap: _exportBackup,
                    ),
                    Divider(height: 1, color: borderColor),
                    ListTile(
                      leading: const Icon(Icons.restore_page_outlined),
                      title: Text(
                        'Yedeği geri yükle',
                        style: TextStyle(color: titleColor),
                      ),
                      subtitle: Text(
                        'Seçilen JSON yedeğini cihaza geri al',
                        style: TextStyle(color: subtitleColor),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Color(0xFFFFC83D),
                      ),
                      onTap: _importBackup,
                    ),
                    Divider(height: 1, color: borderColor),
                    ListTile(
                      leading: const Icon(Icons.playlist_add_rounded),
                      title: Text(
                        'Paylaşılan repertuarı içe aktar',
                        style: TextStyle(color: titleColor),
                      ),
                      subtitle: Text(
                        '`.akorsetlist` veya JSON dosyası seç',
                        style: TextStyle(color: subtitleColor),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Color(0xFFFFC83D),
                      ),
                      onTap: _importSharedSetlist,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              GoogleAuthWidget(
                mode: GoogleAuthMode.card,
                isDark: isDark,
                cardBg: cardBg,
                borderColor: borderColor,
                titleColor: titleColor,
                subtitleColor: subtitleColor,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hesap Yönetimi',
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Bu cihazdaki hesap verilerini tamamen sil.',
                      style: TextStyle(color: subtitleColor),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE74C3C),
                          foregroundColor: Colors.white,
                        ),
                        onPressed:
                            _deleteBusy ? null : _deleteAccountAndLocalData,
                        icon: const Icon(Icons.delete_forever),
                        label: Text(
                          _deleteBusy
                              ? 'Siliniyor...'
                              : 'Hesap ve Verileri Sil',
                        ),
                      ),
                    ),
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
