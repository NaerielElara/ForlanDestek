import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:bot_toast/bot_toast.dart';
import 'pages/forlan_support_dialog.dart';

bool _exiting = false;

Future<void> onForlanActiveWindowChanged() async {
  // Hidden Forlan windows keep their portable server and support session alive.
  if (!(isWindows && bind.mainGetAppNameSync() == 'ForlanDestek')) {
    await onActiveWindowChanged();
  }
}

void registerForlanBackgroundLifecycle() {
  unawaited(ForlanSupportSession.instance.restore());
  platformFFI.registerEventHandler('forlan-policy-message', 'forlan-policy-notice', (event) async {
    BotToast.showText(text: event['message']?.toString() ?? '', duration: const Duration(seconds: 8));
  });
  platformFFI.registerEventHandler('forlan-policy-state', 'forlan-policy-state', (event) async {
    ForlanSupportSession.instance.updateConnectionState(event);
  });
  platformFFI.registerEventHandler('forlan-quit', 'forlan-main-exit',
      (_) async {
    await forlanQuitApplication();
  });
}

Future<void> forlanQuitApplication() async {
  if (_exiting) return;
  _exiting = true;
  try {
    await rustDeskWinManager.closeAllSubWindows();
    await bind.mainOnMainWindowClose();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  } catch (error, stack) {
    _exiting = false;
    debugPrint('Forlan Destek kapatılamadı: $error\n$stack');
  }
}
