import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';
import '../state/membership_state.dart';

class MembershipAccessService {
  MembershipAccessService._();

  static const int freeSongLimit = 5;
  static const int freeSetlistLimit = 1;

  static final MembershipAccessService instance = MembershipAccessService._();

  final SongRepo _songRepo = SongRepo();
  final SetlistRepo _setlistRepo = SetlistRepo();

  bool get isFull => MembershipState.instance.isFull;
  bool get isFree => MembershipState.instance.isFree;

  Future<bool> canCreateSetlist() async {
    if (isFull) return true;
    final count = await _setlistRepo.countSetlists();
    return count < freeSetlistLimit;
  }

  Future<bool> canImportSong() async {
    if (isFull) return true;
    final count = await _songRepo.countSongs();
    return count < freeSongLimit;
  }
}
