import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/animated_rotation_widget.dart';
import 'package:flutter_hbb/common/widgets/custom_password.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/connection_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_tab_page.dart';
import 'package:flutter_hbb/desktop/pages/forlan_support_dialog.dart';
import 'package:flutter_hbb/desktop/widgets/update_progress.dart';
import 'package:flutter_hbb/desktop/widgets/forlan_service_indicator.dart';
import 'package:flutter_hbb/desktop/forlan_background_lifecycle.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;
import '../widgets/button.dart';

class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({Key? key}) : super(key: key);

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

Color _homeSurface(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? MyTheme.surface
        : Colors.white;

Color _homeBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? MyTheme.midnight
        : const Color(0xFFF5F7FB);

Color _homeText(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFF4F7FC)
        : const Color(0xFF182230);

Color _homeMuted(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFB6C2D2)
        : const Color(0xFF66758A);

Color _homeBorder(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? MyTheme.stroke
        : const Color(0xFFDCE3ED);

class _DesktopHomePageState extends State<DesktopHomePage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;
  var systemError = '';
  StreamSubscription? _uniLinksSubscription;
  var svcStopped = false.obs;
  var watchIsCanScreenRecording = false;
  var watchIsProcessTrust = false;
  var watchIsInputMonitoring = false;
  var watchIsCanRecordAudio = false;
  Timer? _updateTimer;
  bool isCardClosed = false;
  late final Future<String> _versionFuture;

  final RxBool _editHover = false.obs;
  final RxBool _block = false.obs;

  final GlobalKey _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isIncomingOnly = bind.isIncomingOnly();
    return _buildBlock(
        child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildLeftPane(context),
        if (!isIncomingOnly)
          SizedBox(width: 1, child: ColoredBox(color: _homeBorder(context))),
        if (!isIncomingOnly) Expanded(child: buildRightPane(context)),
      ],
    ));
  }

  Widget _buildBlock({required Widget child}) {
    return buildRemoteBlock(
        block: _block, mask: true, use: canBeBlocked, child: child);
  }

  Widget buildLeftPane(BuildContext context) {
    final isIncomingOnly = bind.isIncomingOnly();
    final isOutgoingOnly = bind.isOutgoingOnly();
    final isForlan =
        bind.mainGetAppNameSync() == 'ForlanDestek' && !isIncomingOnly;
    final isCompact = MediaQuery.of(context).size.height < 700;
    final logoSize =
        isForlan && MediaQuery.of(context).size.height < 630 ? 56.0 : 68.0;
    final children = <Widget>[
      if (!isOutgoingOnly) buildPresetPasswordWarning(),
      Padding(
        padding:
            EdgeInsets.fromLTRB(20, isCompact ? 8 : 12, 20, isCompact ? 6 : 12),
        child: Row(
          children: [
            Container(
              width: logoSize,
              height: logoSize,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: MyTheme.surfaceRaised,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: MyTheme.stroke),
              ),
              child: loadIcon(logoSize - 8),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FORLAN',
                      style: TextStyle(
                          color: _homeText(context),
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5)),
                  Text('DESTEK',
                      style: TextStyle(
                          color: _homeMuted(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.5)),
                ],
              ),
            ),
          ],
        ),
      ),
      buildTip(context),
      if (!isOutgoingOnly && !isForlan) buildServerStatus(context),
      if (!isOutgoingOnly) buildIDBoard(context),
      if (!isOutgoingOnly) buildPasswordBoard(context),
      if (!isIncomingOnly && isForlan) _buildForlanSupportEntry(context),
      FutureBuilder<Widget>(
        future: Future.value(
            Obx(() => buildHelpCards(stateGlobal.updateUrl.value))),
        builder: (_, data) {
          if (data.hasData) {
            if (isIncomingOnly) {
              if (isInHomePage()) {
                Future.delayed(Duration(milliseconds: 300), () {
                  _updateWindowSize();
                });
              }
            }
            return data.data!;
          } else {
            return const Offstage();
          }
        },
      ),
    ];
    if (isIncomingOnly) {
      children.addAll([
        Divider(color: _homeBorder(context)),
        OnlineStatusWidget(
          onSvcStatusChanged: () {
            if (isInHomePage()) {
              Future.delayed(Duration(milliseconds: 300), () {
                _updateWindowSize();
              });
            }
          },
        ).marginOnly(bottom: 6, right: 6)
      ]);
    }
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Container(
        width: isIncomingOnly ? 280.0 : 286.0,
        color: _homeBackground(context),
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: isForlan && !isIncomingOnly
                      ? Column(
                          key: _childKey,
                          children: [...children, const Spacer()],
                        )
                      : SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: Column(
                            key: _childKey,
                            children: children,
                          ),
                        ),
                ),
                if (isForlan && !isIncomingOnly && !isOutgoingOnly)
                  _buildForlanServiceStatus(context)
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Row(
                      children: [
                        FutureBuilder<String>(
                          future: _versionFuture,
                          builder: (context, snapshot) => Text(
                            snapshot.hasData ? 'v${snapshot.data}' : '',
                            style: TextStyle(
                                color: _homeMuted(context), fontSize: 10),
                          ),
                        ),
                        const Spacer(),
                        if (isOutgoingOnly)
                          InkWell(
                            child: Obx(
                              () => Icon(
                                Icons.settings,
                                color: _editHover.value
                                    ? _homeText(context)
                                    : _homeMuted(context),
                                size: 22,
                              ),
                            ),
                            onTap: () => {
                              if (DesktopSettingPage.tabKeys.isNotEmpty)
                                {
                                  DesktopSettingPage.switch2page(
                                      DesktopSettingPage.tabKeys[0])
                                }
                            },
                            onHover: (value) => _editHover.value = value,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForlanServiceStatus(BuildContext context) {
    return Consumer<ServerModel>(builder: (context, model, child) {
      return Obx(() {
        final stopped = svcStopped.value;
        final ready = !stopped && model.connectStatus == 1;
        final connecting = !stopped && model.connectStatus == 0;
        final color = ready
            ? const Color(0xFF4BD6A2)
            : connecting
                ? const Color(0xFFFFBF69)
                : const Color(0xFFFF7D83);
        final status = stopped
            ? translate('Service is not running')
            : ready
                ? 'Servis çalışıyor · Hazır'
                : connecting
                    ? 'Sunucuya bağlanıyor'
                    : 'Sunucuya erişilemiyor';
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 12, 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _homeSurface(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _homeBorder(context)),
          ),
          child: Row(
            children: [
              ForlanServiceIndicator(color: color, pulsing: ready),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const ForlanCompanyLabel(),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: color,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (stopped)
                          Tooltip(
                            message: 'Uzak masaüstü servisini başlat',
                            child: TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: MyTheme.accent,
                                minimumSize: const Size(44, 20),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(
                                    fontSize: 11, fontWeight: FontWeight.w700),
                              ),
                              onPressed: () async {
                                await mainSetBoolOption(
                                    kOptionStopService, false);
                                final nowStopped =
                                    await mainGetBoolOption(kOptionStopService);
                                if (mounted) svcStopped.value = nowStopped;
                              },
                              child: const Text('Başlat'),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FutureBuilder<String>(
                future: _versionFuture,
                builder: (_, snapshot) => Text(
                  snapshot.hasData ? 'v${snapshot.data}' : '',
                  style: const TextStyle(
                    color: Color(0xFF4BD6A2),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    shadows: [
                      Shadow(color: Color(0x804BD6A2), blurRadius: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      });
    });
  }

  Widget _buildForlanSupportEntry(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 12, 4),
      decoration: BoxDecoration(
        color: _homeSurface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _homeBorder(context)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => forlanSupportSelected.value = true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.support_agent, color: MyTheme.accent, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Destek talepleri',
                        style: TextStyle(
                            color: _homeText(context),
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('Lisans ve teknisyen mesajları',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _homeMuted(context), fontSize: 10)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: _homeMuted(context), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  buildRightPane(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: ConnectionPage(),
    );
  }

  Widget buildServerStatus(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.height < 700;
    return Consumer<ServerModel>(builder: (context, model, child) {
      return Obx(() {
        final stopped = svcStopped.value;
        final ready = !stopped && model.connectStatus == 1;
        final connecting = !stopped && model.connectStatus == 0;
        final statusColor = ready
            ? const Color(0xFF4BD6A2)
            : connecting
                ? const Color(0xFFFFBF69)
                : const Color(0xFFFF7D83);
        final statusText = stopped
            ? translate('Service is not running')
            : ready
                ? translate('Ready')
                : connecting
                    ? translate('connecting_status')
                    : translate('not_ready_status');
        return Container(
          margin: EdgeInsets.fromLTRB(16, 3, 12, isCompact ? 4 : 8),
          padding: EdgeInsets.symmetric(
              horizontal: 12, vertical: isCompact ? 6 : 10),
          decoration: BoxDecoration(
            color: _homeSurface(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _homeBorder(context)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: statusColor.withOpacity(0.3), blurRadius: 8)
                  ],
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${getDisplayAppName()} · ${translate('Server')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _homeMuted(context),
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(statusText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: statusColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        );
      });
    });
  }

  buildIDBoard(BuildContext context) {
    final model = gFFI.serverModel;
    final isCompact = MediaQuery.of(context).size.height < 700;
    return Container(
      margin: EdgeInsets.fromLTRB(16, isCompact ? 4 : 8, 12, 4),
      height: isCompact ? 70 : 82,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: _homeSurface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _homeBorder(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Container(
            width: 2,
            decoration: const BoxDecoration(color: MyTheme.accent),
          ).marginOnly(top: 5),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 25,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          translate("ID"),
                          style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.color
                                  ?.withOpacity(0.5)),
                        ).marginOnly(top: 5),
                        buildPopupMenu(context)
                      ],
                    ),
                  ),
                  Flexible(
                    child: Row(children: [
                      Expanded(
                        child: Tooltip(
                          message: translate('Copy to clipboard'),
                          child: GestureDetector(
                            onDoubleTap: () {
                              Clipboard.setData(
                                  ClipboardData(text: model.serverId.text));
                              showToast(translate("Copied"));
                            },
                            child: TextFormField(
                              controller: model.serverId,
                              readOnly: true,
                              decoration: const InputDecoration(
                                filled: false,
                                border: InputBorder.none,
                                contentPadding:
                                    EdgeInsets.symmetric(vertical: 7),
                              ),
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: bind.mainGetAppNameSync() ==
                                          'ForlanDestek'
                                      ? FontWeight.w700
                                      : null),
                            ).workaroundFreezeLinuxMint(),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: translate('Copy to clipboard'),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        color: _homeMuted(context),
                        constraints: const BoxConstraints.tightFor(
                            width: 30, height: 30),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: model.serverId.text));
                          showToast(translate("Copied"));
                        },
                      ),
                    ]),
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildPopupMenu(BuildContext context) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    RxBool hover = false.obs;
    return InkWell(
      onTap: DesktopTabPage.onAddSetting,
      child: Tooltip(
        message: translate('Settings'),
        child: Obx(
          () => CircleAvatar(
            radius: 15,
            backgroundColor: hover.value
                ? Theme.of(context).scaffoldBackgroundColor
                : Theme.of(context).colorScheme.background,
            child: Icon(
              Icons.more_vert_outlined,
              size: 20,
              color: hover.value ? textColor : textColor?.withOpacity(0.5),
            ),
          ),
        ),
      ),
      onHover: (value) => hover.value = value,
    );
  }

  buildPasswordBoard(BuildContext context) {
    return ChangeNotifierProvider.value(
        value: gFFI.serverModel,
        child: Consumer<ServerModel>(
          builder: (context, model, child) {
            return buildPasswordBoard2(context, model);
          },
        ));
  }

  buildPasswordBoard2(BuildContext context, ServerModel model) {
    RxBool refreshHover = false.obs;
    RxBool editHover = false.obs;
    final isCompact = MediaQuery.of(context).size.height < 700;
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final showOneTime = model.approveMode != 'click' &&
        model.verificationMethod != kUsePermanentPassword;
    final passwordText = model.serverPasswd.text;
    final displayPassword =
        showOneTime && RegExp(r'^\d{6}$').hasMatch(passwordText)
            ? '${passwordText.substring(0, 3)} ${passwordText.substring(3)}'
            : passwordText;
    return Container(
      margin: EdgeInsets.fromLTRB(16, isCompact ? 3 : 6, 12, isCompact ? 4 : 8),
      padding:
          EdgeInsets.symmetric(horizontal: 12, vertical: isCompact ? 5 : 9),
      decoration: BoxDecoration(
        color: _homeSurface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _homeBorder(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Container(
            width: 2,
            height: 52,
            decoration: BoxDecoration(color: MyTheme.accent),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AutoSizeText(
                    translate("One-time Password"),
                    style: TextStyle(fontSize: 13, color: _homeMuted(context)),
                    maxLines: 1,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onDoubleTap: () {
                            if (showOneTime) {
                              Clipboard.setData(
                                  ClipboardData(text: model.serverPasswd.text));
                              showToast(translate("Copied"));
                            }
                          },
                          child: SelectableText(
                            displayPassword,
                            style: TextStyle(
                                fontSize: bind.mainGetAppNameSync() ==
                                            'ForlanDestek' &&
                                        showOneTime
                                    ? 22
                                    : 15,
                                fontWeight: bind.mainGetAppNameSync() ==
                                            'ForlanDestek' &&
                                        showOneTime
                                    ? FontWeight.w700
                                    : null),
                          ),
                        ),
                      ),
                      if (showOneTime)
                        IconButton(
                          tooltip: translate('Copy to clipboard'),
                          icon: const Icon(Icons.copy_rounded, size: 17),
                          color: _homeMuted(context),
                          constraints: const BoxConstraints.tightFor(
                              width: 28, height: 28),
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: model.serverPasswd.text));
                            showToast(translate("Copied"));
                          },
                        ).marginOnly(right: 5, top: 4),
                      if (showOneTime)
                        AnimatedRotationWidget(
                          onPressed: () => bind.mainUpdateTemporaryPassword(),
                          child: Tooltip(
                            message: translate('Refresh Password'),
                            child: Obx(() => RotatedBox(
                                quarterTurns: 2,
                                child: Icon(
                                  Icons.refresh,
                                  color: refreshHover.value
                                      ? textColor
                                      : _homeMuted(context),
                                  size: 22,
                                ))),
                          ),
                          onHover: (value) => refreshHover.value = value,
                        ).marginOnly(right: 8, top: 4),
                      if (!bind.isDisableSettings())
                        InkWell(
                          child: Tooltip(
                            message: translate('Change Password'),
                            child: Obx(
                              () => Icon(
                                Icons.edit,
                                color: editHover.value
                                    ? textColor
                                    : _homeMuted(context),
                                size: 22,
                              ).marginOnly(right: 8, top: 4),
                            ),
                          ),
                          onTap: () => DesktopSettingPage.switch2page(
                              SettingsTabKey.safety),
                          onHover: (value) => editHover.value = value,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  buildTip(BuildContext context) {
    final isOutgoingOnly = bind.isOutgoingOnly();
    final isForlan =
        bind.mainGetAppNameSync() == 'ForlanDestek' && !bind.isIncomingOnly();
    final isCompact = MediaQuery.of(context).size.height < 700;
    return Padding(
      padding: EdgeInsets.only(
          left: 20.0,
          right: 16,
          top: isCompact ? 8 : 16,
          bottom: isCompact ? 2 : 5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              if (!isOutgoingOnly)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    translate("Your Desktop"),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
            ],
          ),
          if (!isForlan) SizedBox(height: isCompact ? 4 : 10),
          if (!isOutgoingOnly && !isForlan)
            Text(
              translate("desk_tip"),
              overflow: TextOverflow.clip,
              style: isCompact
                  ? Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11)
                  : Theme.of(context).textTheme.bodySmall,
            ),
          if (isOutgoingOnly)
            Text(
              translate("outgoing_only_desk_tip"),
              overflow: TextOverflow.clip,
              style: isCompact
                  ? Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11)
                  : Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget buildHelpCards(String updateUrl) {
    if ((!bind.isCustomClient() ||
            bind.mainGetAppNameSync() == 'ForlanDestek') &&
        updateUrl.isNotEmpty &&
        !isCardClosed) {
      final isToUpdate = (isWindows || isMacOS) && bind.mainIsInstalled();
      String btnText = isToUpdate ? 'Update' : 'Download';
      GestureTapCallback onPressed = () async {
        final Uri url = Uri.parse(
            'https://github.com/NaerielElara/ForlanDestek/releases/latest');
        await launchUrl(url);
      };
      if (isToUpdate) {
        onPressed = () {
          _showUpdateNotes(updateUrl);
        };
      }
      return buildInstallCard(
          "Status",
          "${translate("new-version-of-{${getDisplayAppName()}}-tip")} (${bind.mainGetNewVersion()}).",
          btnText,
          onPressed,
          closeButton: true,
          help: isToUpdate ? 'Changelog' : null,
          link: isToUpdate
              ? 'https://github.com/NaerielElara/ForlanDestek/releases/tag/${bind.mainGetNewVersion()}'
              : null);
    }
    if (systemError.isNotEmpty) {
      return buildInstallCard("", systemError, "", () {});
    }

    if (isWindows && !bind.isDisableInstallation()) {
      if (!bind.mainIsInstalled()) {
        return buildInstallCard(
            "", bind.isOutgoingOnly() ? "" : "install_tip", "Install",
            () async {
          await rustDeskWinManager.closeAllSubWindows();
          bind.mainGotoInstall();
        });
      } else if (bind.mainIsInstalledLowerVersion()) {
        return buildInstallCard(
            "Status", "Your installation is lower version.", "Click to upgrade",
            () async {
          await rustDeskWinManager.closeAllSubWindows();
          bind.mainUpdateMe();
        });
      }
    } else if (isMacOS) {
      final isOutgoingOnly = bind.isOutgoingOnly();
      if (!(isOutgoingOnly || bind.mainIsCanScreenRecording(prompt: false))) {
        return buildInstallCard("Permissions", "config_screen", "Configure",
            () async {
          bind.mainIsCanScreenRecording(prompt: true);
          // macOS shows the request prompt only once per app, so later
          // presses would do nothing without opening the settings pane.
          launchUrl(Uri.parse(
              'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'));
          watchIsCanScreenRecording = true;
        }, help: 'Help', link: translate("doc_mac_permission"));
      } else if (!isOutgoingOnly && !bind.mainIsProcessTrusted(prompt: false)) {
        return buildInstallCard("Permissions", "config_acc", "Configure",
            () async {
          bind.mainIsProcessTrusted(prompt: true);
          watchIsProcessTrust = true;
        }, help: 'Help', link: translate("doc_mac_permission"));
      } else if (!bind.mainIsCanInputMonitoring(prompt: false)) {
        return buildInstallCard("Permissions", "config_input", "Configure",
            () async {
          bind.mainIsCanInputMonitoring(prompt: true);
          watchIsInputMonitoring = true;
        }, help: 'Help', link: translate("doc_mac_permission"));
      } else if (!isOutgoingOnly &&
          !svcStopped.value &&
          bind.mainIsInstalled() &&
          !bind.mainIsInstalledDaemon(prompt: false)) {
        return buildInstallCard("", "install_daemon_tip", "Install", () async {
          bind.mainIsInstalledDaemon(prompt: true);
        });
      }
      //// Disable microphone configuration for macOS. We will request the permission when needed.
      // else if ((await osxCanRecordAudio() !=
      //     PermissionAuthorizeType.authorized)) {
      //   return buildInstallCard("Permissions", "config_microphone", "Configure",
      //       () async {
      //     osxRequestAudio();
      //     watchIsCanRecordAudio = true;
      //   });
      // }
    } else if (isLinux) {
      if (bind.isOutgoingOnly()) {
        return Container();
      }
      final LinuxCards = <Widget>[];
      if (bind.isSelinuxEnforcing()) {
        // Check is SELinux enforcing, but show user a tip of is SELinux enabled for simple.
        final keyShowSelinuxHelpTip = "show-selinux-help-tip";
        if (bind.mainGetLocalOption(key: keyShowSelinuxHelpTip) != 'N') {
          LinuxCards.add(buildInstallCard(
            "Warning",
            "selinux_tip",
            "",
            () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link:
                'https://rustdesk.com/docs/en/client/linux/#permissions-issue',
            closeButton: true,
            closeOption: keyShowSelinuxHelpTip,
          ));
        }
      }
      if (bind.mainCurrentIsWayland()) {
        LinuxCards.add(buildInstallCard(
            "Warning", "wayland_experiment_tip", "", () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link: 'https://rustdesk.com/docs/en/client/linux/#x11-required'));
      } else if (bind.mainIsLoginWayland()) {
        LinuxCards.add(buildInstallCard("Warning",
            "Login screen using Wayland is not supported", "", () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link: 'https://rustdesk.com/docs/en/client/linux/#login-screen'));
      }
      if (LinuxCards.isNotEmpty) {
        return Column(
          children: LinuxCards,
        );
      }
    }
    if (bind.isIncomingOnly()) {
      return Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton(
          onPressed: () {
            SystemNavigator.pop(); // Close the application
            // https://github.com/flutter/flutter/issues/66631
            if (isWindows) {
              exit(0);
            }
          },
          child: Text(translate('Quit')),
        ),
      ).marginAll(14);
    }
    return Container();
  }

  void _showUpdateNotes(String releaseUrl) {
    final notes = stateGlobal.updateNotes.value.trim();
    final displayNotes = notes.isEmpty
        ? 'Bu sürüm için yayın notu bulunmuyor.'
        : notes
            .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
            .replaceAll(RegExp(r'^[-*]\s+', multiLine: true), '• ');
    gFFI.dialogManager.show((setState, close, context) => CustomAlertDialog(
          title: Text('Forlan Destek güncellemesi ${bind.mainGetNewVersion()}'),
          content: SizedBox(
            width: 480,
            height: 320,
            child: SingleChildScrollView(
              child: SelectableText(displayNotes),
            ),
          ),
          actions: [
            dialogButton('Cancel', onPressed: close, isOutline: true),
            dialogButton('Update', onPressed: () {
              close();
              handleUpdate(releaseUrl);
            }),
          ],
        ));
  }

  Widget buildInstallCard(String title, String content, String btnText,
      GestureTapCallback onPressed,
      {double marginTop = 20.0,
      String? help,
      String? link,
      bool? closeButton,
      String? closeOption}) {
    final isCompact = MediaQuery.of(context).size.height < 700;
    if (bind.mainGetBuildinOption(key: kOptionHideHelpCards) == 'Y' &&
        content != 'install_daemon_tip') {
      return const SizedBox();
    }
    void closeCard() async {
      if (closeOption != null) {
        await bind.mainSetLocalOption(key: closeOption, value: 'N');
        if (bind.mainGetLocalOption(key: closeOption) == 'N') {
          setState(() {
            isCardClosed = true;
          });
        }
      } else {
        setState(() {
          isCardClosed = true;
        });
      }
    }

    if (isWindows &&
        bind.mainGetAppNameSync() == 'ForlanDestek' &&
        !bind.isIncomingOnly()) {
      return _buildForlanHelpCard(title, content, btnText, onPressed,
          help: help,
          link: link,
          closeCard: closeButton == true ? closeCard : null);
    }

    return Stack(
      children: [
        Container(
          margin: EdgeInsets.fromLTRB(
              isWindows && desktopType == DesktopType.main ? 10 : 0,
              isCompact ? 6 : marginTop,
              isWindows && desktopType == DesktopType.main ? 10 : 0,
              bind.isIncomingOnly() ? (isCompact ? 6 : marginTop) : 0),
          child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _homeSurface(context),
                    Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF1B2D49)
                        : const Color(0xFFEEF4FC),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _homeBorder(context)),
              ),
              padding: EdgeInsets.all(isCompact ? 10 : 20),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: (title.isNotEmpty
                          ? <Widget>[
                              Center(
                                  child: Text(
                                translate(title),
                                style: TextStyle(
                                    color: _homeText(context),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15),
                              ).marginOnly(bottom: 6)),
                            ]
                          : <Widget>[]) +
                      <Widget>[
                        if (content.isNotEmpty)
                          Text(
                            translate(content),
                            style: TextStyle(
                                height: isCompact ? 1.25 : 1.5,
                                color: _homeText(context),
                                fontWeight: FontWeight.normal,
                                fontSize: isCompact ? 12 : 13),
                          ).marginOnly(bottom: isCompact ? 8 : 20)
                      ] +
                      (btnText.isNotEmpty
                          ? <Widget>[
                              Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    FixedWidthButton(
                                      width: 150,
                                      padding: 8,
                                      isOutline: true,
                                      animatedHover: btnText == 'Update',
                                      text: translate(btnText),
                                      textColor: _homeText(context),
                                      borderColor: _homeBorder(context),
                                      textSize: 20,
                                      radius: 10,
                                      onTap: onPressed,
                                    )
                                  ])
                            ]
                          : <Widget>[]) +
                      (help != null
                          ? <Widget>[
                              Center(
                                  child: InkWell(
                                      onTap: () async =>
                                          await launchUrl(Uri.parse(link!)),
                                      child: Text(
                                        translate(help),
                                        style: TextStyle(
                                            decoration:
                                                TextDecoration.underline,
                                            color: MyTheme.accent,
                                            fontSize: 12),
                                      )).marginOnly(top: 6)),
                            ]
                          : <Widget>[]))),
        ),
        if (closeButton != null && closeButton == true)
          Positioned(
            top: 18,
            right: 0,
            child: IconButton(
              icon: Icon(
                Icons.close,
                color: _homeMuted(context),
                size: 20,
              ),
              onPressed: closeCard,
            ),
          ),
      ],
    );
  }

  Widget _buildForlanHelpCard(String title, String content, String btnText,
      GestureTapCallback onPressed,
      {String? help, String? link, VoidCallback? closeCard}) {
    final compact = MediaQuery.of(context).size.height < 700;
    final message = content == 'install_tip'
        ? 'Yönetici izni isteyen ekranlar için uygulamayı yükleyin.'
        : content == 'Your installation is lower version.'
            ? 'Kurulu sürümü yenilemek için güncelleyin.'
            : translate(content);
    return Container(
      margin: EdgeInsets.fromLTRB(16, compact ? 6 : 8, 12, 0),
      padding: EdgeInsets.all(compact ? 8 : 12),
      decoration: BoxDecoration(
        color: _homeSurface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _homeBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message.isNotEmpty || title.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Tooltip(
                    message: message,
                    child: Text(message.isEmpty ? translate(title) : message,
                        maxLines: compact ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _homeMuted(context),
                            height: 1.3,
                            fontSize: compact ? 11 : 12)),
                  ),
                ),
                if (closeCard != null)
                  IconButton(
                    constraints:
                        const BoxConstraints.tightFor(width: 22, height: 22),
                    padding: EdgeInsets.zero,
                    tooltip: translate('Close'),
                    icon:
                        Icon(Icons.close, size: 16, color: _homeMuted(context)),
                    onPressed: closeCard,
                  ),
              ],
            ),
          if (btnText.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FixedWidthButton(
                  width: 148,
                  padding: 6,
                  isOutline: true,
                  animatedHover: true,
                  text: translate(btnText),
                  textColor: _homeText(context),
                  borderColor: _homeBorder(context),
                  textSize: 14,
                  radius: 8,
                  onTap: onPressed,
                ),
                if (help != null && link != null) ...[
                  const SizedBox(width: 6),
                  IconButton(
                    constraints:
                        const BoxConstraints.tightFor(width: 30, height: 30),
                    padding: EdgeInsets.zero,
                    tooltip: translate(help),
                    icon: const Icon(Icons.description_outlined,
                        size: 18, color: MyTheme.accent),
                    onPressed: () async => await launchUrl(Uri.parse(link)),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _versionFuture = bind.mainGetVersion();
    _updateTimer = periodic_immediate(const Duration(seconds: 1), () async {
      await gFFI.serverModel.fetchID();
      final error = await bind.mainGetError();
      if (systemError != error) {
        systemError = error;
        setState(() {});
      }
      final v = await mainGetBoolOption(kOptionStopService);
      if (v != svcStopped.value) {
        svcStopped.value = v;
        setState(() {});
      }
      if (watchIsCanScreenRecording) {
        if (bind.mainIsCanScreenRecording(prompt: false)) {
          watchIsCanScreenRecording = false;
          setState(() {});
        }
      }
      if (watchIsProcessTrust) {
        if (bind.mainIsProcessTrusted(prompt: false)) {
          watchIsProcessTrust = false;
          setState(() {});
        }
      }
      if (watchIsInputMonitoring) {
        if (bind.mainIsCanInputMonitoring(prompt: false)) {
          watchIsInputMonitoring = false;
          // Do not notify for now.
          // Monitoring may not take effect until the process is restarted.
          // rustDeskWinManager.call(
          //     WindowType.RemoteDesktop, kWindowDisableGrabKeyboard, '');
          setState(() {});
        }
      }
      if (watchIsCanRecordAudio) {
        if (isMacOS) {
          Future.microtask(() async {
            if ((await osxCanRecordAudio() ==
                PermissionAuthorizeType.authorized)) {
              watchIsCanRecordAudio = false;
              setState(() {});
            }
          });
        } else {
          watchIsCanRecordAudio = false;
          setState(() {});
        }
      }
    });
    Get.put<RxBool>(svcStopped, tag: 'stop-service');
    rustDeskWinManager
        .registerActiveWindowListener(onForlanActiveWindowChanged);

    screenToMap(window_size.Screen screen) => {
          'frame': {
            'l': screen.frame.left,
            't': screen.frame.top,
            'r': screen.frame.right,
            'b': screen.frame.bottom,
          },
          'visibleFrame': {
            'l': screen.visibleFrame.left,
            't': screen.visibleFrame.top,
            'r': screen.visibleFrame.right,
            'b': screen.visibleFrame.bottom,
          },
          'scaleFactor': screen.scaleFactor,
        };

    bool isChattyMethod(String methodName) {
      switch (methodName) {
        case kWindowBumpMouse:
          return true;
      }

      return false;
    }

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      if (!isChattyMethod(call.method)) {
        debugPrint(
            "[Main] call ${call.method} with args ${call.arguments} from window $fromWindowId");
      }
      if (call.method == kWindowMainWindowOnTop) {
        windowOnTop(null);
      } else if (call.method == kWindowRefreshCurrentUser) {
        gFFI.userModel.refreshCurrentUser();
      } else if (call.method == kWindowGetScreenList) {
        return jsonEncode(
            (await window_size.getScreenList()).map(screenToMap).toList());
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      } else if (call.method == kWindowEventShow) {
        await rustDeskWinManager.registerActiveWindow(call.arguments["id"]);
      } else if (call.method == kWindowEventHide) {
        await rustDeskWinManager.unregisterActiveWindow(call.arguments['id']);
      } else if (call.method == kWindowConnect) {
        await connectMainDesktop(
          call.arguments['id'],
          isFileTransfer: call.arguments['isFileTransfer'],
          isViewCamera: call.arguments['isViewCamera'],
          isTerminal: call.arguments['isTerminal'],
          isTcpTunneling: call.arguments['isTcpTunneling'],
          isRDP: call.arguments['isRDP'],
          password: call.arguments['password'],
          forceRelay: call.arguments['forceRelay'],
          connToken: call.arguments['connToken'],
        );
      } else if (call.method == kWindowBumpMouse) {
        return RdPlatformChannel.instance
            .bumpMouse(dx: call.arguments['dx'], dy: call.arguments['dy']);
      } else if (call.method == kWindowEventMoveTabToNewWindow) {
        final args = call.arguments.split(',');
        int? windowId;
        try {
          windowId = int.parse(args[0]);
        } catch (e) {
          debugPrint("Failed to parse window id '${call.arguments}': $e");
        }
        WindowType? windowType;
        try {
          windowType = WindowType.values.byName(args[3]);
        } catch (e) {
          debugPrint("Failed to parse window type '${call.arguments}': $e");
        }
        if (windowId != null && windowType != null) {
          await rustDeskWinManager.moveTabToNewWindow(
              windowId, args[1], args[2], windowType);
        }
      } else if (call.method == kWindowEventOpenMonitorSession) {
        final args = jsonDecode(call.arguments);
        final windowId = args['window_id'] as int;
        final peerId = args['peer_id'] as String;
        final display = args['display'] as int;
        final displayCount = args['display_count'] as int;
        final windowType = args['window_type'] as int;
        final screenRect = parseParamScreenRect(args);
        await rustDeskWinManager.openMonitorSession(
            windowId, peerId, display, displayCount, screenRect, windowType);
      } else if (call.method == kWindowEventRemoteWindowCoords) {
        final windowId = int.tryParse(call.arguments);
        if (windowId != null) {
          return jsonEncode(
              await rustDeskWinManager.getOtherRemoteWindowCoords(windowId));
        }
      }
    });
    _uniLinksSubscription = listenUniLinks();

    if (bind.isIncomingOnly()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateWindowSize();
      });
    }
    WidgetsBinding.instance.addObserver(this);
  }

  _updateWindowSize() {
    RenderObject? renderObject = _childKey.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      if (size != imcomingOnlyHomeSize) {
        imcomingOnlyHomeSize = size;
        windowManager.setSize(getIncomingOnlyHomeSize());
      }
    }
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    Get.delete<RxBool>(tag: 'stop-service');
    _updateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      shouldBeBlocked(_block, canBeBlocked);
    }
  }
}

void setPasswordDialog({VoidCallback? notEmptyCallback}) async {
  final p0 = TextEditingController(text: "");
  final p1 = TextEditingController(text: "");
  var errMsg0 = "";
  var errMsg1 = "";
  final localPasswordSet =
      (await bind.mainGetCommon(key: "local-permanent-password-set")) == "true";
  final permanentPasswordSet =
      (await bind.mainGetCommon(key: "permanent-password-set")) == "true";
  final presetPassword = permanentPasswordSet && !localPasswordSet;
  var canSubmit = false;
  final RxString rxPass = "".obs;
  final rules = [
    DigitValidationRule(),
    UppercaseValidationRule(),
    LowercaseValidationRule(),
    // SpecialCharacterValidationRule(),
    MinCharactersValidationRule(8),
  ];
  final maxLength = bind.mainMaxEncryptLen();
  final statusTip = localPasswordSet
      ? translate('password-hidden-tip')
      : (presetPassword ? translate('preset-password-in-use-tip') : '');
  final showStatusTipOnMobile =
      statusTip.isNotEmpty && !isDesktop && !isWebDesktop;

  gFFI.dialogManager.show((setState, close, context) {
    updateCanSubmit() {
      canSubmit = p0.text.trim().isNotEmpty || p1.text.trim().isNotEmpty;
    }

    submit() async {
      if (!canSubmit) {
        return;
      }
      setState(() {
        errMsg0 = "";
        errMsg1 = "";
      });
      final pass = p0.text.trim();
      if (pass.isNotEmpty) {
        final Iterable violations = rules.where((r) => !r.validate(pass));
        if (violations.isNotEmpty) {
          setState(() {
            errMsg0 =
                '${translate('Prompt')}: ${violations.map((r) => r.name).join(', ')}';
          });
          return;
        }
      }
      if (p1.text.trim() != pass) {
        setState(() {
          errMsg1 =
              '${translate('Prompt')}: ${translate("The confirmation is not identical.")}';
        });
        return;
      }
      final ok = await bind.mainSetPermanentPasswordWithResult(password: pass);
      if (!ok) {
        setState(() {
          errMsg0 = '${translate('Prompt')}: ${translate("Failed")}';
        });
        return;
      }
      if (pass.isNotEmpty) {
        notEmptyCallback?.call();
      }
      close();
    }

    return CustomAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.key, color: MyTheme.accent),
          Text(translate("Set Password")).paddingOnly(left: 10),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: showStatusTipOnMobile ? 0.0 : 6.0,
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    obscureText: true,
                    decoration: InputDecoration(
                        labelText: translate('Password'),
                        errorText: errMsg0.isNotEmpty ? errMsg0 : null),
                    controller: p0,
                    autofocus: true,
                    onChanged: (value) {
                      rxPass.value = value.trim();
                      setState(() {
                        errMsg0 = '';
                        updateCanSubmit();
                      });
                    },
                    maxLength: maxLength,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(child: PasswordStrengthIndicator(password: rxPass)),
              ],
            ).marginOnly(top: 2, bottom: showStatusTipOnMobile ? 2 : 8),
            SizedBox(
              height: showStatusTipOnMobile ? 0.0 : 8.0,
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    obscureText: true,
                    decoration: InputDecoration(
                        labelText: translate('Confirmation'),
                        errorText: errMsg1.isNotEmpty ? errMsg1 : null),
                    controller: p1,
                    onChanged: (value) {
                      setState(() {
                        errMsg1 = '';
                        updateCanSubmit();
                      });
                    },
                    maxLength: maxLength,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ),
            if (statusTip.isNotEmpty)
              Row(
                children: [
                  Icon(Icons.info, color: Colors.amber, size: 18)
                      .marginOnly(right: 6),
                  Expanded(
                      child: Text(
                    statusTip,
                    style: const TextStyle(fontSize: 13, height: 1.1),
                  ))
                ],
              ).marginOnly(top: 6, bottom: 2),
            SizedBox(
              height: showStatusTipOnMobile ? 0.0 : 8.0,
            ),
            Obx(() => Wrap(
                  runSpacing: showStatusTipOnMobile ? 2.0 : 8.0,
                  spacing: 4,
                  children: rules.map((e) {
                    var checked = e.validate(rxPass.value.trim());
                    return Chip(
                        label: Text(
                          e.name,
                          style: TextStyle(
                              color: checked
                                  ? const Color(0xFF0A9471)
                                  : Color.fromARGB(255, 198, 86, 157)),
                        ),
                        backgroundColor: checked
                            ? const Color(0xFFD0F7ED)
                            : Color.fromARGB(255, 247, 205, 232));
                  }).toList(),
                ))
          ],
        ),
      ),
      actions: (() {
        final cancelButton = dialogButton(
          "Cancel",
          icon: Icon(Icons.close_rounded),
          onPressed: close,
          isOutline: true,
        );
        final removeButton = dialogButton(
          "Remove",
          icon: Icon(Icons.delete_outline_rounded),
          onPressed: () async {
            setState(() {
              errMsg0 = "";
              errMsg1 = "";
            });
            final ok =
                await bind.mainSetPermanentPasswordWithResult(password: "");
            if (!ok) {
              setState(() {
                errMsg0 = '${translate('Prompt')}: ${translate("Failed")}';
              });
              return;
            }
            close();
          },
          buttonStyle: ButtonStyle(
              backgroundColor: MaterialStatePropertyAll(Colors.red)),
        );
        final okButton = dialogButton(
          "OK",
          icon: Icon(Icons.done_rounded),
          onPressed: canSubmit ? submit : null,
        );
        if (!isDesktop && !isWebDesktop && localPasswordSet) {
          return [
            Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    cancelButton,
                    const SizedBox(width: 4),
                    removeButton,
                    const SizedBox(width: 4),
                    okButton,
                  ],
                ),
              ),
            ),
          ];
        }
        return [
          cancelButton,
          if (localPasswordSet) removeButton,
          okButton,
        ];
      })(),
      onSubmit: canSubmit ? submit : null,
      onCancel: close,
    );
  });
}
