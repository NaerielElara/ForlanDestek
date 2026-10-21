import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';

class InstallPage extends StatefulWidget {
  const InstallPage({Key? key}) : super(key: key);

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);

  _InstallPageState() {
    Get.put<DesktopTabController>(tabController);
    const label = "install";
    tabController.add(TabInfo(
        key: label,
        label: label,
        closable: false,
        page: _InstallPageBody(
          key: const ValueKey(label),
        )));
  }

  @override
  void dispose() {
    super.dispose();
    Get.delete<DesktopTabController>();
  }

  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
      enableResizeEdges: windowManagerEnableResizeEdges,
      child: Container(
        child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: DesktopTab(controller: tabController)),
      ),
    );
  }
}

class _InstallPageBody extends StatefulWidget {
  const _InstallPageBody({Key? key}) : super(key: key);

  @override
  State<_InstallPageBody> createState() => _InstallPageBodyState();
}

class _InstallPageBodyState extends State<_InstallPageBody>
    with WindowListener {
  late final TextEditingController controller;
  final RxBool startmenu = true.obs;
  final RxBool desktopicon = true.obs;
  final RxBool printer = false.obs;
  final RxBool showProgress = false.obs;
  final RxBool btnEnabled = true.obs;

  _InstallPageBodyState() {
    controller = TextEditingController(text: bind.installInstallPath());
    final installOptions = jsonDecode(bind.installInstallOptions());
    startmenu.value = installOptions['STARTMENUSHORTCUTS'] != '0';
    desktopicon.value = installOptions['DESKTOPSHORTCUTS'] != '0';
    printer.value = installOptions['PRINTER'] == '1';
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    gFFI.close();
    super.onWindowClose();
    windowManager.setPreventClose(false);
    windowManager.close();
  }

  Widget Option(RxBool option,
      {required String label, required IconData icon}) {
    final isDark = Theme.of(this.context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => btnEnabled.value ? option.value = !option.value : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          children: [
            Icon(icon,
                size: 18, color: isDark ? MyTheme.mutedText : Colors.blueGrey),
            const SizedBox(width: 12),
            Expanded(child: Text(translate(label))),
            Obx(() => Checkbox(
                  value: option.value,
                  onChanged: btnEnabled.value
                      ? (value) => option.value = value ?? false
                      : null,
                  activeColor: MyTheme.accent,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? MyTheme.surface : Colors.white;
    final raised = isDark ? MyTheme.surfaceRaised : const Color(0xFFF3F6FA);
    final stroke = isDark ? MyTheme.stroke : const Color(0xFFD9E1EC);
    final muted = isDark ? MyTheme.mutedText : const Color(0xFF627087);
    final textColor = Theme.of(context).colorScheme.onSurface;
    final cardDecoration = BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: stroke),
    );
    final secondaryButtonStyle = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      side: BorderSide(color: stroke),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    );
    return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.background,
        body: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 22, 32, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: raised,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: stroke),
                          ),
                          child: loadIcon(34),
                        ),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(getDisplayAppName(),
                                style: TextStyle(
                                    color: textColor,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700)),
                            Text(translate('Installation'),
                                style: TextStyle(color: muted, fontSize: 13)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: cardDecoration,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(translate('Installation Path'),
                              style: TextStyle(
                                  color: muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: controller,
                                  readOnly: true,
                                  style: const TextStyle(fontSize: 14),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    filled: true,
                                    fillColor: raised,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 11),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(9),
                                      borderSide: BorderSide(color: stroke),
                                    ),
                                  ),
                                ).workaroundFreezeLinuxMint(),
                              ),
                              const SizedBox(width: 10),
                              Obx(() => OutlinedButton.icon(
                                    icon: const Icon(Icons.folder_outlined,
                                        size: 17),
                                    onPressed: btnEnabled.value
                                        ? selectInstallPath
                                        : null,
                                    style: secondaryButtonStyle,
                                    label: Text(translate('Change Path')),
                                  )),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: cardDecoration,
                      child: Column(
                        children: [
                          Option(startmenu,
                              label: 'Create start menu shortcuts',
                              icon: Icons.apps_outlined),
                          Divider(height: 1, color: stroke),
                          Option(desktopicon,
                              label: 'Create desktop icon',
                              icon: Icons.desktop_windows_outlined),
                          Divider(height: 1, color: stroke),
                          Option(printer,
                              label: 'Install {${getDisplayAppName()}} Printer',
                              icon: Icons.print_outlined),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: cardDecoration,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 21, color: muted),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(translate('agreement_tip'),
                                    style: const TextStyle(fontSize: 13)),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () => launchUrlString(
                                      'https://forlanyazilim.com/iletisim/'),
                                  child: Tooltip(
                                    message:
                                        'https://forlanyazilim.com/iletisim/',
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                            translate(
                                                'End-user license agreement'),
                                            style: const TextStyle(
                                                color: MyTheme.accent,
                                                decoration:
                                                    TextDecoration.underline)),
                                        const SizedBox(width: 5),
                                        const Icon(Icons.open_in_new,
                                            size: 14, color: MyTheme.accent),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 15),
                    Obx(() => showProgress.value
                        ? const LinearProgressIndicator(minHeight: 3)
                        : const SizedBox(height: 3)),
                    const SizedBox(height: 10),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Offstage(
                          offstage: bind.installShowRunWithoutInstall(),
                          child: Obx(() => OutlinedButton.icon(
                                icon: const Icon(Icons.screen_share_outlined,
                                    size: 16),
                                label: Text(translate('Run without install')),
                                onPressed: btnEnabled.value
                                    ? () => bind.installRunWithoutInstall()
                                    : null,
                                style: secondaryButtonStyle,
                              )),
                        ),
                        Obx(() => OutlinedButton.icon(
                              icon: const Icon(Icons.close_rounded, size: 16),
                              label: Text(translate('Cancel')),
                              onPressed: btnEnabled.value
                                  ? () => windowManager.close()
                                  : null,
                              style: secondaryButtonStyle,
                            )),
                        Obx(() => ElevatedButton.icon(
                              icon: const Icon(Icons.done_rounded, size: 16),
                              label: Text(translate('Accept and Install')),
                              onPressed: btnEnabled.value ? install : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: MyTheme.accent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(0, 40),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 18),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(9)),
                              ),
                            )),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
  }

  void install() {
    do_install() {
      btnEnabled.value = false;
      showProgress.value = true;
      String args = '';
      if (startmenu.value) args += ' startmenu';
      if (desktopicon.value) args += ' desktopicon';
      if (printer.value) args += ' printer';
      bind.installInstallMe(options: args, path: controller.text);
    }

    do_install();
  }

  void selectInstallPath() async {
    String? install_path = await FilePicker.platform
        .getDirectoryPath(initialDirectory: controller.text);
    if (install_path != null) {
      controller.text = join(install_path, getDisplayAppName());
    }
  }
}
