import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

// --- カード解析用のデータベース定義 ---
final Map<int, String> _stationMap = {
  // スクショからの推定マッピング (乗車時)
  0x6001: 'イオンモール鹿児島',
  0x7009: 'せんてらす前',
  0xB000: '水族館口', // 2026/01/16 10:16
  0xC006: '中央駅',
  0xD000: '脇田', // 2026/01/16 12:55
  0xE006: '水族館前', // 2026/1/29	14:53
  0xE400: '中央駅',
  0xF000: '天文館', // 2026/01/16 13:21
  // スクショからの推定マッピング (降車時・下位ビット?)
  0x0100: '天文館', // 2025/12/19 13:28 (降車100)
  0x0101: '水族館口', // 2025/11/07 13:26 (降車101)
  0x0201: '脇田', // 2026/01/16 10:47 (降車201)
  0x0300: '中央駅',
  0x0301: '水族館前', // 2026/01/16 10:47 (降車301)
  0x2902: '桜島フェリー(桜島港)', // 2025/11/21 17:13
  0x2A06: 'イオンモール鹿児島',
  0x4100: '鹿児島中央駅前',
  0x5600: '水族館前',
  0xA023: '桜島フェリー(鹿児島港)', // 2025/11/21 17:13
  0xB0A6: '水族館前',
  // 参考: CSV上のコード (実機とは異なる可能性があるためコメントアウト)
  // 0x1E84: '天文館',
  // 0x1E85: '脇田',
  // 0x1E8E: '水族館口',
};

enum BalanceParseMethod {
  be1415, // Big Endian (Rapica, etc.)
  le1011, // Little Endian (Suica, etc.)
}

class FeliCaServiceRule {
  final List<int> serviceCode;
  final int blockCount;
  final String description;
  final BalanceParseMethod parseMethod;
  final bool isHistory;

  FeliCaServiceRule({
    required this.serviceCode,
    this.blockCount = 1,
    required this.description,
    required this.parseMethod,
    this.isHistory = false,
  });
}

class FeliCaCardDefinition {
  final String name;
  final List<int> systemCode;
  final List<FeliCaServiceRule> serviceRules;

  FeliCaCardDefinition({
    required this.name,
    required this.systemCode,
    required this.serviceRules,
  });
}

class SuicaHistory {
  final DateTime date;
  final int balance;
  final int amount;
  final bool isCharge;
  final String label;
  // RAPICA用拡張フィールド
  final int? lineCode; // 系統コード (5バイト目)
  final int? enterStationCode; // 乗車停留所コード (6-7バイト目)
  final int? exitStationCode; // 降車停留所コード (8-9バイト目)
  final int? ticketNumber; // 整理券番号
  final List<int> raw; // 生データ (16バイト)

  SuicaHistory({
    required this.date,
    required this.balance,
    required this.amount,
    required this.isCharge,
    required this.label,
    required this.raw,
    this.lineCode,
    this.enterStationCode,
    this.exitStationCode,
    this.ticketNumber,
  });

  @override
  String toString() =>
      '残高: ¥$balance (Station: $enterStationCode -> $exitStationCode)';
}

final List<FeliCaCardDefinition> _cardRegistry = [
  FeliCaCardDefinition(
    name: 'RAPICA/鹿児島共通乗車カード',
    systemCode: [0x81, 0x94],
    serviceRules: [
      FeliCaServiceRule(
        serviceCode: [0x4b, 0x00],
        blockCount: 1,
        description: '属性サービス',
        parseMethod: BalanceParseMethod.be1415,
        isHistory: false,
      ),
      FeliCaServiceRule(
        serviceCode: [0x8f, 0x00],
        blockCount: 35,
        description: '履歴サービス',
        parseMethod: BalanceParseMethod.be1415,
        isHistory: true,
      ),
    ],
  ),
  FeliCaCardDefinition(
    name: '交通系ICカード (Suica/PASMO等)',
    systemCode: [0x00, 0x03],
    serviceRules: [
      FeliCaServiceRule(
        serviceCode: [0x0f, 0x09],
        blockCount: 10,
        description: '利用履歴',
        parseMethod: BalanceParseMethod.le1011,
        isHistory: true,
      ),
    ],
  ),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  String _statusMessage = 'カードをかざしてください';
  String? _balanceDisplay;
  List<SuicaHistory> _history = [];
  bool _isScanning = false;
  late AnimationController _animationController;
  final List<String> _debugLogs = [];
  bool _showDebugLog = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    debugPrint(msg);
    setState(() {
      _debugLogs.insert(
        0,
        '${DateTime.now().toString().split('.').first.split(' ').last}: $msg',
      );
      if (_debugLogs.length > 50) _debugLogs.removeLast();
    });
  }

  void _startNfcSession() async {
    setState(() {
      _isScanning = true;
      _statusMessage = 'スキャン中...';
      _balanceDisplay = null;
      _history = [];
    });

    try {
      _addLog('Checking NFC availability...');
      var isAvailable = await NfcManager.instance.checkAvailability();
      if (isAvailable != NfcAvailability.enabled) {
        _showError('NFCが無効です');
        return;
      }

      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso18092},
        onDiscovered: (NfcTag tag) async {
          _addLog('Tag Detected! KEEP STEADY...');
          await Future.delayed(const Duration(milliseconds: 500));

          try {
            final nfcf = NfcFAndroid.from(tag);
            if (nfcf == null) {
              _addLog('Error: Not FeliCa');
              return;
            }

            await nfcf.setTimeout(3000);
            Uint8List idm = nfcf.manufacturer;
            try {
              final pollRes = await nfcf.transceive(
                Uint8List.fromList([0x06, 0x00, 0xFF, 0xFF, 0x01, 0x00]),
              );
              if (pollRes.length >= 10 && pollRes[1] == 0x01) {
                idm = pollRes.sublist(2, 10);
              }
            } catch (e) {
              _addLog('Polling fail');
            }

            String scStr = nfcf.systemCode
                .map((e) => e.toRadixString(16).padLeft(2, "0"))
                .join("");
            _addLog('SystemCode: $scStr');

            FeliCaCardDefinition? identifiedCard;
            for (var cardDef in _cardRegistry) {
              if (listEquals(nfcf.systemCode, cardDef.systemCode)) {
                identifiedCard = cardDef;
                break;
              }
            }

            if (identifiedCard == null) {
              _showError('非対応カード ($scStr)');
              return;
            }

            DateTime anchorDate = DateTime.now();
            int? latestBalance;
            List<SuicaHistory> collectedHistory = [];
            bool foundBalanceFromHistory = false;
            bool foundBalanceFromAttr = false;

            for (var rule in identifiedCard.serviceRules) {
              List<List<int>> resBlocks = [];

              // 安定性を最大化するため、履歴は1ブロックずつ取得する。
              // (一括読み取りだと一部の古いブロックが存在しない場合にエラーで全滅するため)
              for (int idx = 0; idx < rule.blockCount; idx++) {
                List<int> singleBlockList = [0x80, idx];

                try {
                  var singleBlock = await _readWithoutEncryption(
                    nfcf: nfcf,
                    idm: idm,
                    serviceCode: rule.serviceCode,
                    blockCount: 1,
                    blockList: singleBlockList,
                  );

                  if (singleBlock.isNotEmpty) {
                    resBlocks.addAll(singleBlock);
                  } else {
                    // ブロックが返ってこなくなったらそこで履歴終了とみなす
                    _addLog('End of history at block $idx');
                    break;
                  }

                  // 通信の安定化のためごく短いウェイトを挿入
                  await Future.delayed(const Duration(milliseconds: 20));
                } catch (e) {
                  _addLog('Read block $idx fail: $e');
                  break;
                }
              }

              if (resBlocks.isEmpty) continue;

              // 属性サービスから最新の利用日時(アンカー)を取得
              if (rule.serviceCode[0] == 0x4b) {
                var b = resBlocks[0];
                if (b.length >= 5) {
                  // 時・分まで含むため5バイト以上を確認
                  int y = b[0]; // 年 (Year)
                  int m = b[1]; // 月 (Month)
                  int d = b[2]; // 日 (Day)
                  int h = b[3]; // 時 (Hour)
                  int min = b[4]; // 分 (Minute)

                  if (y > 0 && m > 0 && m <= 12 && d > 0 && d <= 31) {
                    anchorDate = DateTime(2000 + y, m, d, h, min);
                    _addLog(
                      'Card Anchor Info: 20$y/$m/$d $h:${min.toString().padLeft(2, '0')} (Latest)',
                    );
                  }
                }
                continue; // 属性は日付取得のみ
              }

              List<int> blockBalances = [];
              //List<DateTime> blockDates = [];
              List<int> blockTypeBytes = [];
              List<int> tripIds = [];

              for (var b in resBlocks) {
                if (b.length < 16) continue;
                // 詳細な生データログは開発終了のため整理
                // _addLog('H-Block ${resBlocks.indexOf(b)}: ${b.map((e) => e.toRadixString(16).padLeft(2, "0")).join(" ")}');

                int currentBalance = (b[14] << 8 | b[15]);
                int statusType = b[12];
                int tripId = b[0];

                if (currentBalance >= 0 && currentBalance < 200000) {
                  blockBalances.add(currentBalance);
                  blockTypeBytes.add(statusType);
                  tripIds.add(tripId);

                  if (!foundBalanceFromHistory) {
                    latestBalance = currentBalance;
                    foundBalanceFromHistory = true;
                  }
                }
              }

              if (blockBalances.isNotEmpty) {
                for (int i = 0; i < blockBalances.length; i++) {
                  int diff = 0;
                  if (i + 1 < blockBalances.length) {
                    diff = blockBalances[i] - blockBalances[i + 1];
                  }

                  // --- 汎用的な日付決定ロジック ---
                  var b = resBlocks[i];

                  // 1. 基本的な日付形式の解析 (Suica等)
                  int sMonth = 0, sDay = 0, sYear = 0;
                  if (rule.parseMethod == BalanceParseMethod.be1415) {
                    int dateVal = (b[4] << 8) | b[5];
                    sYear = (dateVal >> 9) & 0x7F;
                    sMonth = (dateVal >> 5) & 0x0F;
                    sDay = dateVal & 0x1F;
                  } else {
                    int dateVal = (b[5] << 8) | b[4];
                    sYear = (dateVal >> 9) & 0x7F;
                    sMonth = (dateVal >> 5) & 0x0F;
                    sDay = dateVal & 0x1F;
                  }

                  // 2. カードの種類に応じた最終日時の決定
                  DateTime displayDate;
                  int? line;
                  int? enterStation;
                  int? exitStation;
                  int? ticket;

                  if (identifiedCard.systemCode[0] == 0x81 &&
                      identifiedCard.systemCode[1] == 0x94) {
                    // RAPICA (いわさきグループ仕様):
                    // [B0:B1高4bit] = 月*100 + 日 (12bit)
                    // [B1低4bit:B2] = 時*100 + 分 (12bit)
                    int datePart = (b[0] << 4) | (b[1] >> 4);
                    int timePart = ((b[1] & 0x0F) << 8) | b[2];

                    int month = datePart ~/ 100;
                    int day = datePart % 100;
                    int hour = timePart ~/ 100;
                    int minute = timePart % 100;

                    // 系統・停留所情報の抽出 (参考: http://jennychan.web.fc2.com/format/rapica.html)
                    // B5: 系統コード
                    line = b[5];
                    // B6-B7: 乗車停留所 (整理券番号はB7の下位ビットなどに含まれる可能性があるが、まずは単純結合でコード化)
                    enterStation = (b[6] << 8) | b[7];
                    // B8-B9: 降車停留所
                    exitStation = (b[8] << 8) | b[9];

                    // 整理券番号（推定: B7の下位ビットやB9の下位ビットが使われるケースもあるが、一旦生コードを表示）
                    ticket = 0;

                    // 年の決定: 属性情報のanchorDate月と比較し、未来なら前年とみなす
                    int year = anchorDate.year;
                    if (month > anchorDate.month) {
                      year -= 1;
                    } else if (month == anchorDate.month &&
                        day > anchorDate.day) {
                      year -= 1;
                    }

                    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
                      displayDate = DateTime(year, month, day, hour, minute);
                    } else {
                      displayDate = anchorDate;
                    }
                  } else {
                    // 交通系IC等: 解析した日付ビットをそのまま採用 (Suica形式)
                    if (sMonth >= 1 &&
                        sMonth <= 12 &&
                        sDay >= 1 &&
                        sDay <= 31) {
                      displayDate = DateTime(2000 + sYear, sMonth, sDay);
                    } else {
                      displayDate = anchorDate;
                    }
                  }

                  String finalLabel = '利用';
                  if (diff > 0) {
                    finalLabel = 'チャージ';
                  } else if (diff == 0) {
                    finalLabel = '乗車';
                  } else {
                    finalLabel = (blockTypeBytes[i] == 0x47)
                        ? 'フェリー/窓口精算'
                        : '運賃支払';
                  }

                  // 一番最後の項目は「その前」の残高が存在せず利用額を算出できないため、
                  // ゴミデータ（0円乗車など）に見えるのを避けるために明細からは除外する。
                  if (i < blockBalances.length - 1) {
                    collectedHistory.add(
                      SuicaHistory(
                        date: displayDate,
                        balance: blockBalances[i],
                        amount: diff,
                        isCharge: diff > 0,
                        label: finalLabel,
                        raw: b,
                        lineCode: line,
                        enterStationCode: enterStation,
                        exitStationCode: exitStation,
                        ticketNumber: ticket,
                      ),
                    );
                  }
                }
              }
            }

            if (mounted) {
              setState(() {
                if (foundBalanceFromHistory || foundBalanceFromAttr) {
                  _balanceDisplay = '¥ $latestBalance';
                } else {
                  _balanceDisplay = '¥ ---';
                }
                _history = collectedHistory;
                _isScanning = false;
                _statusMessage = identifiedCard!.name;
              });
            }
          } catch (e) {
            _addLog('解析エラー: $e');
          } finally {
            if (mounted) {
              setState(() {
                _isScanning = false;
              });
            }
            await NfcManager.instance.stopSession();
          }
        },
      );
    } catch (e) {
      _showError('NFCエラー');
      _addLog('Session Error: $e');
    }
  }

  Future<List<List<int>>> _readWithoutEncryption({
    required NfcFAndroid nfcf,
    required List<int> idm,
    required List<int> serviceCode,
    required int blockCount,
    required List<int> blockList,
  }) async {
    List<int> cmd = [
      0x00,
      0x06,
      ...idm,
      0x01,
      ...serviceCode,
      blockCount,
      ...blockList,
    ];
    cmd[0] = cmd.length;
    _addLog(
      'Read Cmd: ${cmd.map((e) => e.toRadixString(16).padLeft(2, "0")).join("")}',
    );

    try {
      final Uint8List res = await nfcf.transceive(Uint8List.fromList(cmd));
      if (res.length < 12) {
        _addLog('Res logic error: length ${res.length}');
        return [];
      }

      int trueOffset = -1;
      // FeliCaレスポンス: [LEN] [0x07] [IDM(8)] [STATUS1] [STATUS2] [NUM_BLOCKS] [DATA...]
      for (int i = 0; i <= res.length - 12; i++) {
        // 2バイト目(Code)が 0x07 であり、IDmが一致する場所を探す
        if (res[i + 1] == 0x07 &&
            res[i + 2] == idm[0] &&
            res[i + 3] == idm[1]) {
          trueOffset = i;
          break;
        }
      }
      if (trueOffset == -1) {
        _addLog('Res IDm mismatch or no header (len: ${res.length})');
        return [];
      }

      int status1 = res[trueOffset + 10];
      int status2 = res[trueOffset + 11];
      if (status1 != 0x00) {
        _addLog(
          'Card Status Error: S1=${status1.toRadixString(16).padLeft(2, "0")} S2=${status2.toRadixString(16).padLeft(2, "0")}',
        );
        return [];
      }

      int numBlocks = res[trueOffset + 12];
      int dataStart = trueOffset + 13;
      List<Uint8List> blocks = [];
      for (int n = 0; n < numBlocks; n++) {
        int start = dataStart + (n * 16);
        if (start + 16 <= res.length) {
          blocks.add(res.sublist(start, start + 16));
        }
      }
      return blocks;
    } catch (e) {
      _addLog('Transceive Fail: $e');
      return [];
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    setState(() {
      _statusMessage = msg;
      _isScanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
                    child: Column(
                      children: [
                        const SizedBox(height: 10),
                        _buildBalanceCard(),
                        const SizedBox(height: 30),
                        _buildHistorySection(),
                        const SizedBox(height: 30),
                        _buildDebugToggle(),
                        if (_showDebugLog) _buildLogSection(),
                        const SizedBox(height: 100),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _isScanning
          ? null
          : Container(
              margin: const EdgeInsets.only(bottom: 20),
              height: 60,
              width: MediaQuery.of(context).size.width * 0.8,
              child: FloatingActionButton.extended(
                onPressed: _startNfcSession,
                label: const Text(
                  'スキャンの開始',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                icon: const Icon(Icons.nfc),
                backgroundColor: const Color(0xFF0EA5E9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
    );
  }

  Future<void> _exportHistory() async {
    if (_history.isEmpty) {
      _showError('共有する履歴がありません');
      return;
    }

    try {
      List<List<dynamic>> rows = [];
      // Header
      rows.add([
        'Date',
        'Time',
        'Type',
        'Station_Line',
        'Station_Enter',
        'Station_Exit',
        'Amount',
        'Balance',
        'Raw_Hex',
      ]);

      // Data
      for (var item in _history) {
        String dateStr =
            '${item.date.year}/${item.date.month.toString().padLeft(2, '0')}/${item.date.day.toString().padLeft(2, '0')}';
        String timeStr =
            '${item.date.hour.toString().padLeft(2, '0')}:${item.date.minute.toString().padLeft(2, '0')}';

        String enterName = '';
        if (item.enterStationCode != null) {
          enterName = _stationMap[item.enterStationCode] ?? 'Unknown';
          enterName +=
              '(${item.enterStationCode!.toRadixString(16).toUpperCase()})';
        }

        String exitName = '';
        if (item.exitStationCode != null) {
          exitName = _stationMap[item.exitStationCode] ?? 'Unknown';
          exitName +=
              '(${item.exitStationCode!.toRadixString(16).toUpperCase()})';
        }

        String rawHex = item.raw
            .map((e) => e.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase();

        rows.add([
          dateStr,
          timeStr,
          item.label,
          item.lineCode?.toRadixString(16).toUpperCase() ?? '',
          enterName,
          exitName,
          item.amount,
          item.balance,
          rawHex,
        ]);
      }

      String csvData = const ListToCsvConverter().convert(rows);
      final directory = await getTemporaryDirectory();
      final path = '${directory.path}/history_export.csv';
      final file = File(path);
      await file.writeAsString(csvData);

      await Share.shareXFiles([XFile(path)], text: 'IC Card History Export');
    } catch (e) {
      _addLog('Export Error: $e');
      _showError('書き出しに失敗しました: $e');
    }
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'IC READER PRO',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Smart Scanner',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  shadows: [
                    Shadow(
                      color: Colors.black26,
                      offset: Offset(0, 2),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            onPressed: _exportHistory,
            icon: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: const Icon(
                Icons.share_outlined, // 共有アイコンに変更 (好みに応じて file_download 等でも可)
                color: Color(0xFF0EA5E9),
              ),
            ),
            tooltip: 'CSV書き出し',
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceCard() {
    return Container(
      width: double.infinity,
      height: 200,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0EA5E9), Color(0xFF2563EB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2563EB).withValues(alpha: 0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Stack(
        children: [
          Positioned(
            top: -20,
            right: -20,
            child: Icon(
              Icons.wifi_tethering,
              size: 120,
              color: Colors.white.withValues(alpha: 0.1),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _statusMessage.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white70,
                  letterSpacing: 1.2,
                  fontSize: 11,
                ),
              ),
              Text(
                _balanceDisplay ?? '¥ ----',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                children: [
                  const Icon(
                    Icons.contactless,
                    color: Colors.white54,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isScanning ? '読取中...' : 'READY',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
          if (_isScanning)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _buildHistorySection() {
    if (_history.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '利用履歴',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        ..._history.map((item) => _buildHistoryItem(item)),
      ],
    );
  }

  Widget _buildHistoryItem(SuicaHistory item) {
    final bool isSpend = item.amount < 0;
    final bool isCharge = item.amount > 0;
    final String amountText = isSpend
        ? '- ¥${item.amount.abs()}'
        : (isCharge ? '+ ¥${item.amount}' : '¥0');
    final Color amountColor = isSpend
        ? Colors.redAccent
        : (isCharge ? Colors.greenAccent : Colors.white70);

    IconData icon = Icons.train;
    if (item.label == '乗車') {
      icon = Icons.login_outlined;
    } else if (item.label == '乗り換え') {
      icon = Icons.loop_outlined;
    } else if (item.label.contains('運賃') ||
        (item.label == '利用') ||
        item.label.contains('フェリー')) {
      icon = Icons.directions_bus;
    } else if (item.label == 'チャージ') {
      icon = Icons.add_circle_outline;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF00ADB5).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF00ADB5), size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${item.date.year}/${item.date.month.toString().padLeft(2, "0")}/${item.date.day.toString().padLeft(2, "0")} ${item.date.hour.toString().padLeft(2, "0")}:${item.date.minute.toString().padLeft(2, "0")}   残高: ¥${item.balance}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                if (item.enterStationCode != null &&
                    item.enterStationCode != 0) ...[
                  Builder(
                    builder: (context) {
                      final enterName =
                          _stationMap[item.enterStationCode] ?? 'Unknown';
                      final exitName =
                          _stationMap[item.exitStationCode] ?? 'Unknown';

                      // ユーザー要望による表示制御:
                      // 乗車(0円)の時は降車情報は不要 -> "-"
                      // 支払(マイナス)の時は乗車情報は不要 -> "-" (※データとしては乗車地があるが、UI上は隠す)
                      String enterStr = '-';
                      String exitStr = '-';

                      if (item.amount == 0) {
                        // 乗車時: 乗車地を表示、降車地は無視
                        enterStr =
                            '$enterName(${item.enterStationCode!.toRadixString(16).toUpperCase()})';
                      } else if (item.amount < 0) {
                        // 支払(降車)時: 降車地を表示、乗車地は無視
                        // ※ユーザー要望「降りているので乗には表示が出ないはず」に対応
                        exitStr =
                            '$exitName(${item.exitStationCode!.toRadixString(16).toUpperCase()})';
                      } else {
                        // それ以外(チャージ等?): 両方表示しておく
                        enterStr =
                            '$enterName(${item.enterStationCode!.toRadixString(16).toUpperCase()})';
                        exitStr =
                            '$exitName(${item.exitStationCode!.toRadixString(16).toUpperCase()})';
                      }

                      return Text(
                        '系統:${item.lineCode}  乗:$enterStr  降:$exitStr',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          Text(
            amountText,
            style: TextStyle(
              color: amountColor,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugToggle() {
    return TextButton.icon(
      onPressed: () => setState(() => _showDebugLog = !_showDebugLog),
      icon: const Icon(Icons.code, size: 14),
      label: Text(_showDebugLog ? 'ログを隠す' : '技術ログを表示'),
      style: TextButton.styleFrom(foregroundColor: Colors.white24),
    );
  }

  Widget _buildLogSection() {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      height: 250,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'CONSOLE',
                style: TextStyle(
                  color: Colors.white30,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.copy_all,
                  size: 18,
                  color: Colors.white30,
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _debugLogs.join('\n')));
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('ログをコピーしました')));
                },
              ),
            ],
          ),
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                itemCount: _debugLogs.length,
                itemBuilder: (context, index) => Text(
                  _debugLogs[index],
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
