import 'package:shared_preferences/shared_preferences.dart';

class AppSession {
  static const _kGroupId = 'active_group_id';
  static const _kGroupCode = 'active_group_code';
  static const _kHunterId = 'active_hunter_id';
  static const _kHunterName = 'active_hunter_name';
  static const _kHunterRole = 'active_hunter_role';
  static const _kUserId = 'active_user_id'; // ✅ Новое поле

  static String? groupId;
  static String? groupCode;
  static String? hunterId;
  static String? hunterName;
  static String? hunterRole;
  static String? userId;

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
    hunterRole = prefs.getString(_kHunterRole) ?? 'shooter';
    userId = prefs.getString(_kUserId);
  }

  static Future<void> save({
    required String groupId,
    required String groupCode,
    required String hunterId,
    required String hunterName,
    required String hunterRole,
    required String userId, // ✅ Новый параметр
  }) async {
    AppSession.groupId = groupId;
    AppSession.groupCode = groupCode;
    AppSession.hunterId = hunterId;
    AppSession.hunterName = hunterName;
    AppSession.hunterRole = hunterRole;
    AppSession.userId = userId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kGroupId, groupId);
    await prefs.setString(_kGroupCode, groupCode);
    await prefs.setString(_kHunterId, hunterId);
    await prefs.setString(_kHunterName, hunterName);
    await prefs.setString(_kHunterRole, hunterRole);
    await prefs.setString(_kUserId, userId);
  }

  static Future<void> clear() async {
    groupId = null;
    groupCode = null;
    hunterId = null;
    hunterName = null;
    hunterRole = null;
    userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kGroupId);
    await prefs.remove(_kGroupCode);
    await prefs.remove(_kHunterId);
    await prefs.remove(_kHunterName);
    await prefs.remove(_kHunterRole);
    await prefs.remove(_kUserId);
  }
}
