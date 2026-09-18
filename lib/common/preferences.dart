import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bett_box/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constant.dart';
import 'path.dart';
import 'print.dart';

class Preferences {
  static Preferences? _instance;
  Completer<SharedPreferences?> sharedPreferencesCompleter = Completer();

  Future<bool> get isInit async => await sharedPreferencesCompleter.future != null;

  Preferences._internal() {
    SharedPreferences.getInstance()
        .then((value) => sharedPreferencesCompleter.complete(value))
        .onError((_, _) => sharedPreferencesCompleter.complete(null));
  }

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  Future<ClashConfig?> getClashConfig() async {
    final preferences = await sharedPreferencesCompleter.future;
    final clashConfigString = preferences?.getString(clashConfigKey);
    if (clashConfigString == null) return null;
    try {
      final clashConfigMap = json.decode(clashConfigString);
      return ClashConfig.fromJson(clashConfigMap);
    } catch (e, stackTrace) {
      commonPrint.log('Failed to parse clash config from preferences: $e\n$stackTrace');
      return null;
    }
  }

  Future<Config?> getConfig() async {
    final preferences = await sharedPreferencesCompleter.future;

    Config? fileConfig;
    try {
      final configFilePath = await appPath.appConfigPath;
      final configFile = File(configFilePath);
      if (await configFile.exists()) {
        final content = await configFile.readAsString();
        if (content.isNotEmpty) {
          final configMap = json.decode(content);
          fileConfig = Config.compatibleFromJson(configMap);
        }
      }
    } catch (e, stackTrace) {
      commonPrint.log('Failed to parse config from file: $e\n$stackTrace');
    }

    Config? prefsConfig;
    try {
      final configString = preferences?.getString(configKey);
      if (configString != null && configString.isNotEmpty) {
        final configMap = json.decode(configString);
        prefsConfig = Config.compatibleFromJson(configMap);
      }
    } catch (e, stackTrace) {
      commonPrint.log('Failed to parse config from preferences: $e\n$stackTrace');
    }

    Config? selectedConfig;
    if (fileConfig != null && prefsConfig != null) {
      if (fileConfig.profiles.isEmpty && prefsConfig.profiles.isNotEmpty) {
        selectedConfig = prefsConfig;
        await saveConfig(prefsConfig);
      } else {
        selectedConfig = fileConfig;
      }
    } else {
      selectedConfig = fileConfig ?? prefsConfig;
      if (selectedConfig != null && fileConfig == null) {
        await saveConfig(selectedConfig);
      }
    }

    if (selectedConfig == null || selectedConfig.profiles.isEmpty) {
      final healedProfiles = await _autoHealProfilesFromDisk();
      if (healedProfiles.isNotEmpty) {
        final base = selectedConfig ?? Config(themeProps: defaultThemeProps);
        selectedConfig = base.copyWith(
          profiles: healedProfiles,
          currentProfileId: base.currentProfileId ?? healedProfiles.first.id,
        );
        await saveConfig(selectedConfig);
      }
    }

    if (selectedConfig != null &&
        preferences?.getBool('autoLaunch') != selectedConfig.appSetting.autoLaunch) {
      await preferences?.setBool('autoLaunch', selectedConfig.appSetting.autoLaunch);
    }

    return selectedConfig;
  }

  Future<List<Profile>> _autoHealProfilesFromDisk() async {
    final profiles = <Profile>[];
    try {
      final profilesDirPath = await appPath.profilesPath;
      final profilesDir = Directory(profilesDirPath);
      if (!await profilesDir.exists()) return profiles;

      final entries = await profilesDir.list(recursive: false).toList();
      for (final entry in entries) {
        if (entry is! File) continue;
        final fileName = entry.path.split(Platform.pathSeparator).last;
        if (!fileName.endsWith('.yaml') && !fileName.endsWith('.yml')) continue;

        final id = fileName.replaceAll(RegExp(r'\.(yaml|yml)$'), '');
        String label = id;

        try {
          final lines = await entry
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .take(30)
              .toList();
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.startsWith('#')) {
              final comment = trimmed.substring(1).trim();
              if (comment.isNotEmpty &&
                  comment.length < 50 &&
                  !comment.startsWith('!')) {
                label = comment;
                break;
              }
            }
          }
        } catch (_) {}

        profiles.add(
          Profile(
            id: id,
            label: label,
            autoUpdateDuration: defaultUpdateDuration,
            url: '',
          ),
        );
      }
      if (profiles.isNotEmpty) {
        commonPrint.log('Auto-healed ${profiles.length} profiles from disk');
      }
    } catch (e, stackTrace) {
      commonPrint.log('Auto-healing profiles failed: $e\n$stackTrace');
    }
    return profiles;
  }

  Future<bool> saveConfig(Config config) async {
    final preferences = await sharedPreferencesCompleter.future;
    await preferences?.setBool('autoLaunch', config.appSetting.autoLaunch);

    final jsonStr = json.encode(config);

    try {
      await preferences?.setString(configKey, jsonStr);
    } catch (e) {
      commonPrint.log('Failed to mirror config to preferences: $e');
    }

    try {
      final configFilePath = await appPath.appConfigPath;
      final targetFile = File(configFilePath);
      final tempFile = File('$configFilePath.tmp');
      await tempFile.parent.create(recursive: true);
      await tempFile.writeAsString(jsonStr, flush: true);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await tempFile.rename(configFilePath);
      return true;
    } catch (e, stackTrace) {
      commonPrint.log('Failed to save config to file: $e\n$stackTrace');
      return false;
    }
  }

  Future<void> clearClashConfig() async {
    final preferences = await sharedPreferencesCompleter.future;
    preferences?.remove(clashConfigKey);
  }

  Future<void> clearPreferences() async {
    final sharedPreferencesIns = await sharedPreferencesCompleter.future;
    await sharedPreferencesIns?.clear();
    try {
      final file = File(await appPath.appConfigPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    try {
      final ipFile = File(await appPath.ipCacheFilePath);
      if (await ipFile.exists()) {
        await ipFile.delete();
      }
    } catch (_) {}
  }
}

final preferences = Preferences();
