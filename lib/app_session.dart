import 'package:shared_preferences/shared_preferences.dart';

class AppSession {
  static const _kGroupId = 'active_group_id';
  static const _kGroupCode = 'active_group_code';
  static const _kHunterId = 'active_hunter_id';
  static const _kHunterName = 'active_hunter_name';

  static String? groupId;
  static String? groupCode;
  static String? hunterId;
  static String? hunterName;

  static bool get hasSession =>
      groupId != null &&
      groupCode != null &&
      hunterId != null &&
      hunterName != null;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    groupId = prefs.getString(_kGroupId);
    groupCode = prefs.getString(_kGroupCode);
    hunterId = prefs.getString(_kHunterId);
    hunterName = prefs.getString(_kHunterName);
  }

  static Future<void> save({
    required String groupId,
    required String groupCode,
    required String hunterId,
    required String hunterName,
  }) async {
    AppSession.groupId = groupId;
    AppSession.groupCode = groupCode;
    AppSession.hunterId = hunterId;
    AppSession.hunterName = hunterName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kGroupId, groupId);
    await prefs.setString(_kGroupCode, groupCode);
    await prefs.setString(_kHunterId, hunterId);
    await prefs.setString(_kHunterName, hunterName);
  }

  static Future<void> clear() async {
    groupId = null;
    groupCode = null;
    hunterId = null;
    hunterName = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kGroupId);
    await prefs.remove(_kGroupCode);
    await prefs.remove(_kHunterId);
    await prefs.remove(_kHunterName);
  }
}
