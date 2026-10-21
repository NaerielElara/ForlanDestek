import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

final _isExtracting = false.obs;

void handleUpdate(String releasePageUrl) {
  _isExtracting.value = false;
  final isForlanUpdate =
      isWindows && bind.mainGetAppNameSync() == 'ForlanDestek';
  String downloadUrl = releasePageUrl.replaceAll('tag', 'download');
  String version = downloadUrl.substring(downloadUrl.lastIndexOf('/') + 1);
  final String downloadFile =
      bind.mainGetCommonSync(key: 'download-file-$version');
  if (downloadFile.startsWith('error:')) {
    final error = downloadFile.replaceFirst('error:', '');
    msgBox(gFFI.sessionId, 'custom-nocancel-nook-hasclose', 'Error', error,
        isForlanUpdate ? '' : releasePageUrl, gFFI.dialogManager);
    return;
  }
  downloadUrl = '$downloadUrl/$downloadFile';

  SimpleWrapper downloadId = SimpleWrapper('');
  SimpleWrapper<VoidCallback> onCanceled = SimpleWrapper(() {});
  gFFI.dialogManager.dismissAll();
  gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
        title: Obx(() => Text(isForlanUpdate
            ? (_isExtracting.isTrue
                ? 'Forlan Destek kuruluyor'
                : 'Forlan Destek indiriliyor')
            : translate(_isExtracting.isTrue
                ? 'Preparing for installation ...'
                : 'Downloading {$appName}'))),
        content: SizedBox(
                width: isForlanUpdate ? 420 : null,
                child: UpdateProgress(
                    releasePageUrl, downloadUrl, downloadId, onCanceled))
            .marginSymmetric(horizontal: 8)
            .paddingOnly(top: 12),
        actions: [
          Obx(() => _isExtracting.isFalse
              ? dialogButton(translate('Cancel'), onPressed: () async {
                  onCanceled.value();
                  await bind.mainSetCommon(
                      key: 'cancel-downloader', value: downloadId.value);
                  // Wait for the downloader to be removed.
                  for (int i = 0; i < 10; i++) {
                    await Future.delayed(const Duration(milliseconds: 300));
                    final isCanceled = 'error:Downloader not found' ==
                        await bind.mainGetCommon(
                            key: 'download-data-${downloadId.value}');
                    if (isCanceled) {
                      break;
                    }
                  }
                  close();
                }, isOutline: true)
              : const SizedBox.shrink()),
        ]);
  });
}

class UpdateProgress extends StatefulWidget {
  final String releasePageUrl;
  final String downloadUrl;
  final SimpleWrapper downloadId;
  final SimpleWrapper onCanceled;
  UpdateProgress(
      this.releasePageUrl, this.downloadUrl, this.downloadId, this.onCanceled,
      {Key? key})
      : super(key: key);

  @override
  State<UpdateProgress> createState() => UpdateProgressState();
}

class UpdateProgressState extends State<UpdateProgress> {
  Timer? _timer;
  final Stopwatch _downloadClock = Stopwatch();
  int? _totalSize;
  int _downloadedSize = 0;
  int _getDataFailedCount = 0;
  bool _installing = false;
  final String _eventKeyDownloadNewVersion = 'download-new-version';
  final String _eventKeyExtractUpdateDmg = 'extract-update-dmg';
  final String _eventKeyForlanUpdateLaunch = 'forlan-update-launch';

  bool get _isForlan =>
      isWindows && bind.mainGetAppNameSync() == 'ForlanDestek';

  @override
  void initState() {
    super.initState();
    widget.onCanceled.value = () {
      cancelQueryTimer();
    };
    platformFFI.registerEventHandler(_eventKeyDownloadNewVersion,
        _eventKeyDownloadNewVersion, handleDownloadNewVersion,
        replace: true);
    if (_isForlan) {
      platformFFI.registerEventHandler(_eventKeyForlanUpdateLaunch,
          _eventKeyForlanUpdateLaunch, handleForlanUpdateLaunch,
          replace: true);
    }
    bind.mainSetCommon(key: 'download-new-version', value: widget.downloadUrl);
    if (isMacOS) {
      platformFFI.registerEventHandler(_eventKeyExtractUpdateDmg,
          _eventKeyExtractUpdateDmg, handleExtractUpdateDmg,
          replace: true);
    }
  }

  @override
  void dispose() {
    cancelQueryTimer();
    platformFFI.unregisterEventHandler(
        _eventKeyDownloadNewVersion, _eventKeyDownloadNewVersion);
    if (_isForlan) {
      platformFFI.unregisterEventHandler(
          _eventKeyForlanUpdateLaunch, _eventKeyForlanUpdateLaunch);
    }
    if (isMacOS) {
      platformFFI.unregisterEventHandler(
          _eventKeyExtractUpdateDmg, _eventKeyExtractUpdateDmg);
    }
    super.dispose();
  }

  void cancelQueryTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> handleDownloadNewVersion(Map<String, dynamic> evt) async {
    if (evt.containsKey('id')) {
      widget.downloadId.value = evt['id'] as String;
      _timer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
        _updateDownloadData();
      });
    } else {
      if (evt.containsKey('error')) {
        _onError(evt['error'] as String);
      } else {
        // unreachable
        _onError('$evt');
      }
    }
  }

  Future<void> handleForlanUpdateLaunch(Map<String, dynamic> evt) async {
    final error = evt['error'];
    if (error != null) {
      _onError(error.toString());
    }
  }

  // `isExtractDmg` is true when handling extract-update-dmg event.
  // It's a rare case that the dmg file is corrupted and cannot be extracted.
  void _onError(String error, {bool isExtractDmg = false}) {
    cancelQueryTimer();
    if (_isForlan) {
      _isExtracting.value = false;
      gFFI.dialogManager.dismissAll();
      gFFI.dialogManager.show((setState, close, context) => CustomAlertDialog(
            title: const Text('Güncelleme başarısız'),
            content: SizedBox(
              width: 420,
              child: SelectableText(
                  'Güncelleme tamamlanamadı. Bağlantınızı kontrol edip yeniden deneyin.\n\n$error'),
            ),
            actions: [
              dialogButton('Yeniden dene', onPressed: () {
                close();
                handleUpdate(widget.releasePageUrl);
              }),
              dialogButton('Kapat', onPressed: close, isOutline: true),
            ],
          ));
      return;
    }

    debugPrint(
        '${isExtractDmg ? "Extract" : "Download"} new version error: $error');
    final msgBoxType = 'custom-nocancel-nook-hasclose';
    final msgBoxTitle = 'Error';
    final msgBoxText = 'download-new-version-failed-tip';
    final dialogManager = gFFI.dialogManager;

    close() {
      dialogManager.dismissAll();
    }

    jumplink() {
      launchUrl(Uri.parse(widget.releasePageUrl));
      dialogManager.dismissAll();
    }

    retry() {
      dialogManager.dismissAll();
      handleUpdate(widget.releasePageUrl);
    }

    final List<Widget> buttons = [
      dialogButton('Download', onPressed: jumplink),
      if (!isExtractDmg) dialogButton('Retry', onPressed: retry),
      dialogButton('Close', onPressed: close),
    ];
    dialogManager.dismissAll();
    dialogManager.show(
      (setState, close, context) => CustomAlertDialog(
        title: null,
        content: SelectionArea(
            child: msgboxContent(msgBoxType, msgBoxTitle, msgBoxText)),
        actions: buttons,
      ),
      tag: '$msgBoxType-$msgBoxTitle-$msgBoxTitle',
    );
  }

  void _updateDownloadData() {
    String err = '';
    String downloadData =
        bind.mainGetCommonSync(key: 'download-data-${widget.downloadId.value}');
    if (downloadData.startsWith('error:')) {
      err = downloadData.substring('error:'.length);
    } else {
      try {
        jsonDecode(downloadData).forEach((key, value) {
          if (key == 'total_size') {
            if (value != null && value is int) {
              _totalSize = value;
            }
          } else if (key == 'downloaded_size') {
            _downloadedSize = value as int;
            if (_downloadedSize > 0 && !_downloadClock.isRunning) {
              _downloadClock.start();
            }
          } else if (key == 'error') {
            if (value != null) {
              err = value.toString();
            }
          }
        });
      } catch (e) {
        _getDataFailedCount += 1;
        debugPrint(
            'Failed to get download data ${widget.downloadUrl}, error $e');
        if (_getDataFailedCount > 3) {
          err = e.toString();
        }
      }
    }
    if (err != '') {
      _onError(err);
    } else {
      if (_totalSize != null && _downloadedSize >= _totalSize!) {
        cancelQueryTimer();
        bind.mainSetCommon(
            key: 'remove-downloader', value: widget.downloadId.value);
        if (_totalSize == 0) {
          _onError('The download file size is 0.');
        } else {
          setState(() {});
          if (isMacOS) {
            bind.mainSetCommon(
                key: 'extract-update-dmg', value: widget.downloadUrl);
            _isExtracting.value = true;
          } else {
            updateMsgBox();
          }
        }
      } else {
        setState(() {});
      }
    }
  }

  void updateMsgBox() {
    if (_isForlan) {
      _installing = true;
      _isExtracting.value = true;
      setState(() {});
      bind.mainSetCommon(key: 'update-me', value: widget.downloadUrl);
      return;
    }
    msgBox(
      gFFI.sessionId,
      'custom-nocancel',
      '{$appName} Update',
      '{$appName}-to-update-tip',
      '',
      gFFI.dialogManager,
      onSubmit: () {
        debugPrint('Downloaded, update to new version now');
        bind.mainSetCommon(key: 'update-me', value: widget.downloadUrl);
      },
      submitTimeout: 5,
    );
  }

  Future<void> handleExtractUpdateDmg(Map<String, dynamic> evt) async {
    _isExtracting.value = false;
    if (evt.containsKey('err') && (evt['err'] as String).isNotEmpty) {
      _onError(evt['err'] as String, isExtractDmg: true);
    } else {
      updateMsgBox();
    }
  }

  @override
  Widget build(BuildContext context) {
    getValue() => _totalSize == null
        ? 0.0
        : (_totalSize == 0 ? 1.0 : _downloadedSize / _totalSize!);
    if (_isForlan) {
      final percent = (_totalSize == null || _totalSize == 0)
          ? 0
          : (100 * _downloadedSize / _totalSize!).clamp(0, 100).round();
      final seconds = _downloadClock.elapsedMilliseconds / 1000;
      final speed = seconds > 0 ? _downloadedSize / seconds : 0.0;
      String size(num bytes) {
        if (bytes >= 1024 * 1024) {
          return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        }
        if (bytes >= 1024) {
          return '${(bytes / 1024).toStringAsFixed(0)} KB';
        }
        return '${bytes.toStringAsFixed(0)} B';
      }

      final muted = Theme.of(context).colorScheme.onSurface.withOpacity(0.68);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_installing
              ? 'İndirme tamamlandı. Yeni sürüm kuruluyor; Windows yönetici izni isteyebilir.'
              : 'Yeni sürüm uygulama içinde indirilecek ve otomatik kurulacak.'),
          const SizedBox(height: 20),
          LinearProgressIndicator(
            value: _installing || _totalSize == null ? null : getValue(),
            minHeight: 12,
            borderRadius: BorderRadius.circular(6),
            backgroundColor:
                Theme.of(context).colorScheme.onSurface.withOpacity(0.12),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1677FF)),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Text(_installing ? 'Kurulum başlatılıyor' : '%$percent',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(
                _installing
                    ? 'Hazır'
                    : '${size(_downloadedSize)} / ${_totalSize == null ? '—' : size(_totalSize!)}',
                style: TextStyle(color: muted)),
          ]),
          if (!_installing) ...[
            const SizedBox(height: 6),
            Text('İndirme hızı: ${size(speed)}/sn',
                style: TextStyle(color: muted)),
          ],
        ],
      );
    }
    return LinearProgressIndicator(
      value: _isExtracting.isTrue ? null : getValue(),
      minHeight: 20,
      borderRadius: BorderRadius.circular(5),
      backgroundColor: Colors.grey[300],
      valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
    );
  }
}
