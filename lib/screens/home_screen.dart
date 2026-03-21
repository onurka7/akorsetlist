import 'package:flutter/material.dart';

import 'chord_detection_screen.dart';
import 'chords_screen.dart';
import 'settings_screen.dart';
import 'setlists_screen.dart';
import 'tuner_screen.dart';
import 'web_search_screen.dart';

class HomeScreen extends StatefulWidget {
  final bool isDarkMode;
  final ValueChanged<bool>? onThemeChanged;

  const HomeScreen({
    super.key,
    this.isDarkMode = true,
    this.onThemeChanged,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  int idx = 0;
  int? _activeSetlistId;
  int _tunerBackIndex = 0;
  int _chordDetectionBackIndex = 2;

  // Setlists ekranını "yenilemek" için
  final ValueNotifier<int> setlistsRefresh = ValueNotifier<int>(0);
  final ValueNotifier<int> setlistsCreateRequest = ValueNotifier<int>(0);
  final GlobalKey<SetlistsScreenState> setlistsKey =
      GlobalKey<SetlistsScreenState>();
  final GlobalKey<WebSearchScreenState> webSearchKey =
      GlobalKey<WebSearchScreenState>();

  void _onTabSelected(int v) {
    if (idx == 1 && v != 1) {
      webSearchKey.currentState?.dismissKeyboard();
    }
    if (v == 1) {
      webSearchKey.currentState?.showFrequentSearches();
    }
    if (v == 0) {
      setlistsKey.currentState?.showDashboardHome();
    }
    setState(() => idx = v);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _openAllSongs() {
    if (idx == 1) {
      webSearchKey.currentState?.dismissKeyboard();
    }
    setlistsKey.currentState?.showAllSongs();
    setState(() => idx = 0);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _openTuner({required int backIndex}) {
    _tunerBackIndex = backIndex;
    _onTabSelected(4);
  }

  void _openChordDetection({required int backIndex}) {
    _chordDetectionBackIndex = backIndex;
    _onTabSelected(5);
  }

  @override
  void dispose() {
    setlistsRefresh.dispose();
    setlistsCreateRequest.dispose();
    super.dispose();
  }

  Widget _navItem({
    required IconData icon,
    required String label,
    required int index,
    bool? selectedOverride,
    VoidCallback? onTap,
  }) {
    final selected = selectedOverride ?? idx == index;
    final iconColor =
        selected ? const Color(0xFF151515) : const Color(0xFFD9D9D9);
    final textColor =
        selected ? const Color(0xFF151515) : const Color(0xFFBEBEBE);

    return Expanded(
      child: GestureDetector(
        onTap: onTap ?? () => _onTabSelected(index),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFFC83D) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFFFFC83D).withValues(alpha: 0.28),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: iconColor, size: 24),
              const SizedBox(height: 4),
              SizedBox(
                height: 14,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final currentTopTab = setlistsKey.currentState?.currentTopTab;
    final inDashboardHome = idx == 0 && currentTopTab == -1;
    final inAllSongs = idx == 0 && currentTopTab == 0;

    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      child: Container(
        height: 86,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF111111).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.30),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Row(
          children: [
            _navItem(
              icon: Icons.home_rounded,
              label: "Ana Sayfa",
              index: 0,
              selectedOverride: inDashboardHome,
            ),
            _navItem(icon: Icons.search_rounded, label: "Ara", index: 1),
            _navItem(
              icon: Icons.music_note_rounded,
              label: "Tüm Şarkılar",
              index: 0,
              selectedOverride: inAllSongs,
              onTap: _openAllSongs,
            ),
            _navItem(
              icon: Icons.settings_rounded,
              label: "Ayarlar",
              index: 3,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: idx,
        children: [
          // ✅ DİKKAT: SetlissScreen değil, SetlistsScreen
          SetlistsScreen(
            key: setlistsKey,
            refresh: setlistsRefresh,
            createRequest: setlistsCreateRequest,
            isDarkMode: widget.isDarkMode,
            onThemeChanged: widget.onThemeChanged,
            onQuickAction: (action) {
              if (action == 'chords') {
                _onTabSelected(2);
                return;
              }
              if (action == 'tuner') {
                _openTuner(backIndex: 0);
                return;
              }
              if (action == 'chord_detection') {
                _openChordDetection(backIndex: 0);
                return;
              }
            },
            onActiveSetlistChanged: (setlistId) {
              if (!mounted) return;
              setState(() => _activeSetlistId = setlistId);
            },
          ),
          WebSearchScreen(
            key: webSearchKey,
            setlistId: _activeSetlistId ?? -1,
            onGoHome: () => _onTabSelected(0),
            onImported: () {
              setlistsRefresh.value++;
              setState(() => idx = 0); // import sonrası Setlist'e dön
            },
          ),
          ChordsScreen(
            isDarkMode: widget.isDarkMode,
            onBack: () => _onTabSelected(0),
            onGoHome: () => _onTabSelected(0),
            onOpenTuner: () => _openTuner(backIndex: 2),
          ),
          SettingsScreen(
            isDarkMode: widget.isDarkMode,
            onThemeChanged: widget.onThemeChanged,
          ),
          TunerScreen(
            isDarkMode: widget.isDarkMode,
            onBack: () => _onTabSelected(_tunerBackIndex),
            onGoHome: () => _onTabSelected(0),
          ),
          ChordDetectionScreen(
            isDarkMode: widget.isDarkMode,
            onBack: () => _onTabSelected(_chordDetectionBackIndex),
            onGoHome: () => _onTabSelected(0),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }
}
