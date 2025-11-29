import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

// Intent used to trigger quiz "check or next" via Enter key (works even when TextField loses focus)
class _NextIntent extends Intent {
  const _NextIntent();
}

class ResultScreen extends StatelessWidget {
  final String mode;
  final int score;
  final int total;
  final List<Map<String, dynamic>> incorrect;
  final VoidCallback onRetry;

  const ResultScreen(
      {Key? key,
      required this.mode,
      required this.score,
      required this.total,
      required this.incorrect,
      required this.onRetry})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final percent = ((score / (total == 0 ? 1 : total)) * 100).round();
    return Scaffold(
      appBar: AppBar(title: Text('$mode - 結果')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              color: Colors.indigo.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('スコア',
                              style: TextStyle(color: Colors.grey[700])),
                          const SizedBox(height: 6),
                          Text('$score / $total',
                              style: const TextStyle(
                                  fontSize: 24, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Text('$percent%',
                              style: const TextStyle(fontSize: 18)),
                        ],
                      ),
                    ),
                    CircularProgressIndicator(
                        value: total == 0 ? 0 : score / total),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('戻る')),
              ],
            ),
            const SizedBox(height: 12),
            const Text('間違えた問題', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: incorrect.isEmpty
                  ? const Center(child: Text('おめでとうございます。間違いはありません。'))
                  : ListView.builder(
                      itemCount: incorrect.length,
                      itemBuilder: (c, i) {
                        final it = incorrect[i];
                        final q = it['question'] ?? it['question'] ?? '';
                        final a = it['answers'] != null
                            ? (it['answers'] is List
                                ? (it['answers'] as List).join(' / ')
                                : it['answers'].toString())
                            : (it['answer'] ?? '');
                        return ListTile(
                          title: Text(q.toString()),
                          subtitle: Text('解答: $a'),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// Modes are managed dynamically. Each mode corresponds to one imported JSON file.
// Display name uses the mode key by default. Users can add/remove modes.

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '単語・一問一答クイズ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.indigo),
      // MaterialLocalizations are provided by MaterialApp.
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, List<Map<String, dynamic>>> allData = {};
  Map<String, Map<String, String>> masteryStatus = {}; // mode -> {id: status}
  Map<String, Set<String>> deletedIds = {}; // mode -> set of ids
  List<String> modes = [];

  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadStoredData();
  }

  Future<void> _loadStoredData() async {
    final prefs = await SharedPreferences.getInstance();
    // Load list of modes and per-mode data from SharedPreferences
    modes = prefs.getStringList('modes') ?? [];
    for (final mode in modes) {
      final raw = prefs.getString('data_${mode}');
      if (raw != null) {
        try {
          final list = json.decode(raw) as List<dynamic>;
          // Ensure each item has a stable string id for mastery tracking.
          var updated = false;
          final normalized = <Map<String, dynamic>>[];
          for (var i = 0; i < list.length; i++) {
            final e = list[i];
            if (e is Map<String, dynamic>) {
              final copy = Map<String, dynamic>.from(e);
              if (!copy.containsKey('id') ||
                  copy['id'] == null ||
                  copy['id'].toString().isEmpty) {
                copy['id'] = 'id_${DateTime.now().millisecondsSinceEpoch}_$i';
                updated = true;
              } else {
                copy['id'] = copy['id'].toString();
              }
              normalized.add(copy);
            }
          }
          allData[mode] = normalized;
          if (updated) {
            // persist back with generated ids
            await prefs.setString('data_${mode}', json.encode(normalized));
            // stored mastery keys won't match newly generated ids; clear stored mastery
            await prefs.remove('${mode}MasteryStatus');
            masteryStatus[mode] = {};
          }
        } catch (e) {
          allData[mode] = [];
        }
      } else {
        allData[mode] = [];
      }

      final saved = prefs.getString('${mode}MasteryStatus');
      if (saved != null) {
        try {
          final map = Map<String, dynamic>.from(json.decode(saved));
          masteryStatus[mode] = map.map((k, v) => MapEntry(k, v.toString()));
        } catch (e) {
          masteryStatus[mode] = {};
        }
      } else {
        masteryStatus[mode] = {};
      }
      final del = prefs.getStringList('deleted_${mode}');
      deletedIds[mode] = del != null ? del.toSet() : <String>{};
    }

    setState(() {
      loading = false;
    });
  }

  // (removed deprecated helper)

  Future<void> _importJsonFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null) return;
      final bytes = result.files.first.bytes;
      if (bytes == null) {
        _showSnack('ファイルの読み取りに失敗しました（バイナリ取得不可）。');
        return;
      }
      final content = const Utf8Decoder().convert(bytes);

      // Expect the imported JSON to be either:
      // - a List (single-mode array)
      // - a Map with an `items` List (single-mode wrapper)
      // - a Map whose top-level keys map to Lists (multiple modes in one file)
      final dynamic parsed = json.decode(content);
      List<dynamic>? itemsList;
      if (parsed is List) {
        itemsList = parsed;
      } else if (parsed is Map && parsed['items'] is List) {
        itemsList = List<dynamic>.from(parsed['items']);
      } else if (parsed is Map) {
        // If top-level is a map of modeName -> list, allow choosing keys to import.
        final candidateKeys =
            parsed.keys.where((k) => parsed[k] is List).toList();
        if (candidateKeys.isEmpty) {
          _showSnack('このファイルはインポート可能な問題配列を含んでいません。');
          return;
        }

        // Ask user which keys to import (allow multiple selection)
        final toImport = <String>{};
        final picked = await showDialog<bool>(
            context: context,
            builder: (ctx) {
              return StatefulBuilder(builder: (ctx2, setState2) {
                return AlertDialog(
                  title: const Text('ファイル内のモードを選択'),
                  content: SizedBox(
                    width: 300,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: candidateKeys
                            .map((k) => CheckboxListTile(
                                  value: toImport.contains(k),
                                  title: Text(k),
                                  onChanged: (v) {
                                    setState2(() {
                                      if (v == true)
                                        toImport.add(k);
                                      else
                                        toImport.remove(k);
                                    });
                                  },
                                ))
                            .toList(),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx2).pop(false),
                        child: const Text('キャンセル')),
                    ElevatedButton(
                        onPressed: () => Navigator.of(ctx2).pop(true),
                        child: const Text('インポート'))
                  ],
                );
              });
            });

        if (picked != true || toImport.isEmpty) return;

        final prefs = await SharedPreferences.getInstance();
        final updatedModes = (prefs.getStringList('modes') ?? []).toList();
        for (final key in toImport) {
          final rawList = List<dynamic>.from(parsed[key]);
          // ensure ids for imported items
          for (var i = 0; i < rawList.length; i++) {
            final item = rawList[i];
            if (item is Map<String, dynamic>) {
              if (!item.containsKey('id') ||
                  item['id'] == null ||
                  item['id'].toString().isEmpty) {
                item['id'] = 'id_${DateTime.now().millisecondsSinceEpoch}_$i';
              } else {
                item['id'] = item['id'].toString();
              }
            }
          }
          var modeName = key.toString();
          // avoid name collision
          if (updatedModes.contains(modeName)) {
            var i = 1;
            while (updatedModes.contains('$modeName($i)')) i++;
            modeName = '$modeName($i)';
          }
          await prefs.setString('data_${modeName}', json.encode(rawList));
          updatedModes.add(modeName);
          // reset related storage
          await prefs.remove('${modeName}MasteryStatus');
          await prefs.remove('deleted_${modeName}');
          masteryStatus[modeName] = {};
          deletedIds[modeName] = <String>{};
          allData[modeName] =
              rawList.whereType<Map<String, dynamic>>().map((e) {
            final copy = Map<String, dynamic>.from(e);
            if (copy.containsKey('id')) copy['id'] = copy['id'].toString();
            return copy;
          }).toList();
        }
        await prefs.setStringList('modes', updatedModes);
        modes = updatedModes;
        setState(() {});
        _showSnack('ファイル内のモードをインポートしました。');
        return;
      } else {
        _showSnack(
            'このファイルは単一モードの問題配列ではありません。配列（JSONのトップが []）か、モード名->配列 の形式を使ってください。');
        return;
      }

      // Ask user to select an existing mode or provide a new mode name.
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getStringList('modes') ?? [];
      String? chosenMode = await showDialog<String>(
          context: context,
          builder: (ctx) {
            String newMode = '';
            String? selected = existing.isNotEmpty ? existing.first : null;
            return StatefulBuilder(builder: (ctx2, setState2) {
              return AlertDialog(
                title: const Text('モードを選択 / 追加'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (existing.isNotEmpty)
                    DropdownButton<String>(
                        value: selected,
                        items: existing
                            .map((e) =>
                                DropdownMenuItem(value: e, child: Text(e)))
                            .toList(),
                        onChanged: (v) {
                          setState2(() {
                            selected = v;
                          });
                        }),
                  const SizedBox(height: 8),
                  TextField(
                      onChanged: (v) => newMode = v.trim(),
                      decoration:
                          const InputDecoration(labelText: '新しいモード名（任意）')),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(ctx2).pop(null),
                      child: const Text('キャンセル')),
                  ElevatedButton(
                      onPressed: () {
                        final result = (newMode.isNotEmpty)
                            ? newMode
                            : (selected ??
                                'mode_${DateTime.now().millisecondsSinceEpoch}');
                        Navigator.of(ctx2).pop(result);
                      },
                      child: const Text('決定')),
                ],
              );
            });
          });
      if (chosenMode == null) return;

      final mode = chosenMode;
      // ensure ids then persist per-mode data
      for (var i = 0; i < itemsList.length; i++) {
        final item = itemsList[i];
        if (item is Map<String, dynamic>) {
          if (!item.containsKey('id') ||
              item['id'] == null ||
              item['id'].toString().isEmpty) {
            item['id'] = 'id_${DateTime.now().millisecondsSinceEpoch}_$i';
          } else {
            item['id'] = item['id'].toString();
          }
        }
      }
      await prefs.setString('data_${mode}', json.encode(itemsList));
      final updatedModes = (prefs.getStringList('modes') ?? []).toList();
      if (!updatedModes.contains(mode)) {
        updatedModes.add(mode);
        await prefs.setStringList('modes', updatedModes);
      }
      // clear mastery/deleted for this mode
      await prefs.remove('${mode}MasteryStatus');
      await prefs.remove('deleted_${mode}');
      masteryStatus[mode] = {};
      deletedIds[mode] = <String>{};

      // update runtime data
      allData[mode] = itemsList.whereType<Map<String, dynamic>>().map((e) {
        final copy = Map<String, dynamic>.from(e);
        if (copy.containsKey('id')) copy['id'] = copy['id'].toString();
        return copy;
      }).toList();
      modes = (prefs.getStringList('modes') ?? []);
      setState(() {});
      _showSnack('JSONをインポートしました（モード: $mode）。');
    } catch (e, st) {
      debugPrint('import error $e\n$st');
      _showSnack('インポートに失敗しました。ファイル形式を確認してください。');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openManageScreen(String mode) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (c) => ManageScreen(
              mode: mode,
              items: allData[mode] ?? [],
              deleted: deletedIds[mode] ?? <String>{},
              onDeleteChanged: (newDeleted) async {
                deletedIds[mode] = newDeleted;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setStringList(
                    'deleted_${mode}', newDeleted.toList());
                setState(() {});
              },
            )));
  }

  Future<void> _addMode() async {
    final prefs = await SharedPreferences.getInstance();
    String newMode = '';
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('新しいモードを追加'),
            content: TextField(
                onChanged: (v) => newMode = v.trim(),
                decoration: const InputDecoration(labelText: 'モード名')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('キャンセル')),
              ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('追加')),
            ],
          );
        });
    if (ok != true) return;
    if (newMode.isEmpty) {
      _showSnack('モード名を入力してください。');
      return;
    }
    final modesList = (prefs.getStringList('modes') ?? []).toList();
    if (modesList.contains(newMode)) {
      _showSnack('同名のモードが既に存在します。');
      return;
    }
    modesList.add(newMode);
    await prefs.setStringList('modes', modesList);
    await prefs.setString('data_${newMode}', json.encode([]));
    allData[newMode] = [];
    masteryStatus[newMode] = {};
    deletedIds[newMode] = <String>{};
    modes = modesList;
    setState(() {});
    _showSnack('モードを追加しました: $newMode');
  }

  void _openStartScreen(String mode) {
    final items = (allData[mode] ?? [])
        .where(
            (it) => !(deletedIds[mode]?.contains(it['id'].toString()) ?? false))
        .toList();
    if (items.isEmpty) {
      _showSnack('出題可能な問題がありません。まずJSONをインポートするか、削除を解除してください。');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
        builder: (c) => StartScreen(
              mode: mode,
              items: items,
              masteryStatus: masteryStatus[mode] ?? {},
              onSaveMastery: (m) async {
                masteryStatus[mode] = m;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('${mode}MasteryStatus', json.encode(m));
              },
            )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('単語・一問一答クイズ'),
        actions: [
          IconButton(
              onPressed: _importJsonFile,
              icon: const Icon(Icons.file_upload),
              tooltip: 'JSONをインポート'),
          IconButton(
              onPressed: () => _showAbout(context),
              icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('モードを選択',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Expanded(
                    child: modes.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                    'まだモードがありません。右上のアップロードからJSONをインポートするか、モードを追加してください。'),
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                    onPressed: _importJsonFile,
                                    icon: const Icon(Icons.file_upload),
                                    label: const Text('JSONをインポート')),
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                    onPressed: _addMode,
                                    icon: const Icon(Icons.add),
                                    label: const Text('モードを追加')),
                              ],
                            ),
                          )
                        : GridView.count(
                            crossAxisCount:
                                (MediaQuery.of(context).size.width ~/ 300)
                                    .clamp(1, 4),
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            children: modes.map((mode) {
                              return SizedBox(
                                width: 260,
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(mode,
                                            style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold)),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            ElevatedButton(
                                                onPressed: () =>
                                                    _openStartScreen(mode),
                                                child: const Text('開始')),
                                            const SizedBox(width: 8),
                                            OutlinedButton(
                                                onPressed: () =>
                                                    _openManageScreen(mode),
                                                child: const Text('問題管理')),
                                            const SizedBox(width: 8),
                                            IconButton(
                                              tooltip: 'モードを削除',
                                              icon: const Icon(
                                                  Icons.delete_forever),
                                              color: Colors.red,
                                              onPressed: () async {
                                                final ok =
                                                    await showDialog<bool>(
                                                        context: context,
                                                        builder: (ctx) =>
                                                            AlertDialog(
                                                              title: const Text(
                                                                  'モード削除の確認'),
                                                              content: Text(
                                                                  'モード「$mode」を削除しますか？この操作は復元できません。'),
                                                              actions: [
                                                                TextButton(
                                                                    onPressed: () =>
                                                                        Navigator.of(ctx).pop(
                                                                            false),
                                                                    child: const Text(
                                                                        'キャンセル')),
                                                                ElevatedButton(
                                                                    onPressed: () =>
                                                                        Navigator.of(ctx).pop(
                                                                            true),
                                                                    child:
                                                                        const Text(
                                                                            '削除'))
                                                              ],
                                                            ));
                                                if (ok == true) {
                                                  await _deleteMode(mode);
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        _buildStatsRow(mode),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                  ),
                  const SizedBox(height: 12),
                  const Text('操作メモ',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                      '・右上のアップロードボタンでJSONをインポートしてください。\n・インポート後は「問題管理」で削除や復元が可能です。\n・学習履歴はモードごとに保存されます。'),
                ],
              ),
            ),
    );
  }

  Widget _buildStatsRow(String mode) {
    final items = allData[mode] ?? [];
    final filtered = items
        .where(
            (it) => !(deletedIds[mode]?.contains(it['id'].toString()) ?? false))
        .toList();
    final status = masteryStatus[mode] ?? {};
    int unattempted = 0, unlearned = 0, checking = 0, mastered = 0;
    for (final it in filtered) {
      final s = status[it['id'].toString()] ?? '未実施';
      switch (s) {
        case '未習得':
          unlearned++;
          break;
        case '点検中':
          checking++;
          break;
        case '習得':
          mastered++;
          break;
        default:
          unattempted++;
      }
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('問題:${filtered.length}'),
        Text('未実施:$unattempted'),
        Text('未習得:$unlearned'),
        Text('点検中:$checking'),
        Text('習得:$mastered'),
      ],
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: '単語・一問一答クイズ',
      applicationVersion: '0.1.0',
      children: const [Text('JSONをインポートして利用する学習用クイズアプリのサンプル実装です。')],
    );
  }

  Future<void> _deleteMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    final modesList = (prefs.getStringList('modes') ?? []).toList();
    modesList.remove(mode);
    await prefs.setStringList('modes', modesList);
    await prefs.remove('data_${mode}');
    await prefs.remove('${mode}MasteryStatus');
    await prefs.remove('deleted_${mode}');
    allData.remove(mode);
    masteryStatus.remove(mode);
    deletedIds.remove(mode);
    modes = modesList;
    setState(() {});
    _showSnack('モード「$mode」を削除しました。');
  }
}

class ManageScreen extends StatefulWidget {
  final String mode;
  final List<Map<String, dynamic>> items;
  final Set<String> deleted;
  final ValueChanged<Set<String>> onDeleteChanged;

  const ManageScreen(
      {Key? key,
      required this.mode,
      required this.items,
      required this.deleted,
      required this.onDeleteChanged})
      : super(key: key);

  @override
  State<ManageScreen> createState() => _ManageScreenState();
}

class _ManageScreenState extends State<ManageScreen> {
  late Set<String> deleted;

  @override
  void initState() {
    super.initState();
    deleted = Set<String>.from(widget.deleted);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.mode} - 問題管理')),
      body: ListView.builder(
        itemCount: widget.items.length,
        itemBuilder: (c, i) {
          final it = widget.items[i];
          final id = it['id'].toString();
          final title =
              it['question'] ?? it['question'] ?? (it['answer'] ?? '(無題)');
          final isDeleted = deleted.contains(id);
          final answersList = <String>[];
          if (it['answers'] != null) {
            if (it['answers'] is List) {
              for (final a in it['answers']) answersList.add(a.toString());
            } else {
              answersList.add(it['answers'].toString());
            }
          } else if (it['answer'] != null) {
            answersList.add(it['answer'].toString());
          }

          return ListTile(
            leading: CircleAvatar(child: Text('${i + 1}')),
            title: Text(title.toString(),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: answersList.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: answersList
                          .map((a) => Chip(
                              label: Text(a),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap))
                          .toList(),
                    ),
                  ),
            trailing: IconButton(
              icon: Icon(
                  isDeleted ? Icons.restore_from_trash : Icons.delete_outline,
                  color: isDeleted ? Colors.orange : null),
              onPressed: () async {
                setState(() {
                  if (isDeleted)
                    deleted.remove(id);
                  else
                    deleted.add(id);
                });
                widget.onDeleteChanged(deleted);
              },
            ),
          );
        },
      ),
    );
  }
}

class StartScreen extends StatefulWidget {
  final String mode;
  final List<Map<String, dynamic>> items;
  final Map<String, String> masteryStatus;
  final Future<void> Function(Map<String, String>) onSaveMastery;

  const StartScreen(
      {Key? key,
      required this.mode,
      required this.items,
      required this.masteryStatus,
      required this.onSaveMastery})
      : super(key: key);

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  late Map<String, String> status;
  int selectedCount = 10;

  @override
  void initState() {
    super.initState();
    status = Map<String, String>.from(widget.masteryStatus);
  }

  void _startQuiz({required bool all}) {
    final pool = List<Map<String, dynamic>>.from(widget.items);
    pool.shuffle();
    final quizItems =
        all ? pool : pool.take(selectedCount.clamp(1, pool.length)).toList();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (c) => QuizScreen(
              mode: widget.mode,
              items: quizItems,
              status: status,
              onStatusChange: (m) async {
                setState(() {
                  status = m;
                });
                await widget.onSaveMastery(m);
              },
            )));
  }

  void _resetHistory() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('リセット確認'),
              content: const Text('学習履歴をリセットしますか？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('キャンセル')),
                ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('リセット'))
              ],
            ));
    if (ok == true) {
      setState(() {
        status.clear();
      });
      await widget.onSaveMastery(status);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('履歴をリセットしました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ensure items are safe Maps to avoid runtime JS-to-Dart conversion issues on web.
    final items = widget.items.map<Map<String, dynamic>>((dynamic raw) {
      if (raw is Map<String, dynamic>) return Map<String, dynamic>.from(raw);
      try {
        return Map<String, dynamic>.from(raw as Map);
      } catch (_) {
        return {
          'id': raw.hashCode.toString(),
          'question': raw.toString(),
          'answer': ''
        };
      }
    }).toList();

    int unattempted = 0, unlearned = 0, checking = 0, mastered = 0;
    for (final it in items) {
      final id = (it['id'] ?? '').toString();
      final s = status[id] ?? '未実施';
      switch (s) {
        case '未習得':
          unlearned++;
          break;
        case '点検中':
          checking++;
          break;
        case '習得':
          mastered++;
          break;
        default:
          unattempted++;
      }
    }

    final isMobilePlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    final isMobile = isMobilePlatform || isSmallScreen;

    Widget mainBody = Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${items.length} 問',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Card(
            color: Colors.indigo.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('習得率', style: TextStyle(fontSize: 14)),
                        const SizedBox(height: 6),
                        Text('$mastered / ${widget.items.length} (習得)',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 円グラフ風の習得表示: 円と中央に習得数を表示
                  SizedBox(
                    width: 120,
                    height: 120,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 96,
                          height: 96,
                          child: CircularProgressIndicator(
                            value: items.isEmpty
                                ? 0
                                : mastered / items.length.toDouble(),
                            strokeWidth: 10,
                            color: Colors.indigo,
                            backgroundColor: Colors.white,
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$mastered',
                                style: const TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            const Text('習得', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(children: [
            Text('未実施:$unattempted'),
            const SizedBox(width: 8),
            Text('未習得:$unlearned'),
            const SizedBox(width: 8),
            Text('点検中:$checking'),
            const SizedBox(width: 8),
            Text('習得:$mastered')
          ]),
          const SizedBox(height: 16),
          if (!isMobile)
            Row(children: [
              Expanded(
                  child: ElevatedButton(
                      onPressed: () => _startQuiz(all: false),
                      child: const Text('ランダム10問'))),
              const SizedBox(width: 8),
              Expanded(
                  child: ElevatedButton(
                      onPressed: () => _startQuiz(all: true),
                      child: const Text('全範囲')))
            ]),
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: _resetHistory, child: const Text('学習履歴をリセット')),
          const SizedBox(height: 12),
          Expanded(
              child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (c, i) {
                    final it = items[i];
                    final id = it['id'].toString();
                    final q = (it['question'] ?? it['answer'] ?? '').toString();
                    final a = it['answers'] != null
                        ? (it['answers'] is List
                            ? (it['answers'] as List).join(' / ')
                            : it['answers'].toString())
                        : (it['answer'] ?? '');
                    final s = status[id] ?? '未実施';
                    return ListTile(
                      title: Text(q.toString()),
                      subtitle: Text('$a'),
                      trailing: Text(s),
                    );
                  })),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(widget.mode)),
      body: mainBody,
      bottomNavigationBar: isMobile
          ? SafeArea(
              minimum: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('戻る')),
                  const SizedBox(width: 8),
                  // 出題数選択
                  DropdownButton<int>(
                      value: selectedCount,
                      items: <int>[5, 10, 20, 50]
                          .map((e) =>
                              DropdownMenuItem(value: e, child: Text('$e')))
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          selectedCount = v;
                        });
                      }),
                  const SizedBox(width: 8),
                  Expanded(
                      child: ElevatedButton(
                          onPressed: () => _startQuiz(all: false),
                          child: Text('ランダム $selectedCount 問'))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                      onPressed: () => _startQuiz(all: true),
                      child: const Text('全範囲')),
                ],
              ),
            )
          : null,
    );
  }
}

class QuizScreen extends StatefulWidget {
  final String mode;
  final List<Map<String, dynamic>> items;
  final Map<String, String> status;
  final Future<void> Function(Map<String, String>) onStatusChange;

  const QuizScreen(
      {Key? key,
      required this.mode,
      required this.items,
      required this.status,
      required this.onStatusChange})
      : super(key: key);

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  late List<Map<String, dynamic>> quizItems;
  int index = 0;
  int score = 0;
  final TextEditingController ctrl = TextEditingController();
  String feedback = '';
  bool checkedCurrent = false;
  bool lastAnswerCorrect = false;
  final List<Map<String, dynamic>> incorrectItems = [];

  @override
  void initState() {
    super.initState();
    quizItems = List<Map<String, dynamic>>.from(widget.items);
  }

  // Intent used for keyboard shortcut handling (Enter key)
  // defined here so Actions can refer to it

  Map<String, String> get statusMap => widget.status;
  void _check() async {
    final user = ctrl.text.trim();
    final cur = quizItems[index];
    final id = cur['id'].toString();
    bool correct = false;
    String correctText = '';
    if (widget.mode == 'english' || widget.mode == 'kobun') {
      correctText = (cur['answer'] ?? '').toString();
      correct = _normalize(user) == _normalize(correctText);
    } else {
      final answers = (cur['answers'] ?? []);
      if (answers is List) {
        correctText = answers.join(' / ');
        final nu = _normalize(user);
        for (final a in answers) {
          if (_normalize(a.toString()) == nu) {
            correct = true;
            break;
          }
        }
      }
    }

    final curStatus = statusMap[id] ?? '未実施';
    if (!checkedCurrent) {
      if (correct && user.isNotEmpty) {
        score++;
        if (curStatus == '未実施' || curStatus == '未習得')
          statusMap[id] = '点検中';
        else if (curStatus == '点検中') statusMap[id] = '習得';
        feedback = '正解！';
        lastAnswerCorrect = true;
      } else {
        statusMap[id] = '未習得';
        feedback = '不正解。正解: $correctText';
        lastAnswerCorrect = false;
        incorrectItems.add(cur);
      }
      checkedCurrent = true;
      await widget.onStatusChange(statusMap);
      setState(() {});
    }
  }

  void _next() {
    if (index < quizItems.length - 1) {
      index++;
      ctrl.clear();
      feedback = '';
      checkedCurrent = false;
      lastAnswerCorrect = false;
      setState(() {});
    } else {
      _showResult();
    }
  }

  void _checkOrNext() {
    if (!checkedCurrent) {
      _check();
    } else {
      _next();
    }
  }

  String _normalize(String s) {
    return s.trim().toLowerCase().replaceAll(RegExp(r"\s+"), '');
  }

  void _showResult() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (c) => ResultScreen(
              mode: widget.mode,
              score: score,
              total: quizItems.length,
              incorrect: incorrectItems,
              onRetry: () {
                // pop ResultScreen to return to StartScreen
                Navigator.of(context).pop();
              },
            )));
  }

  @override
  Widget build(BuildContext context) {
    final cur = quizItems[index];
    final q = cur['question'] ?? cur['question'] ?? '';
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.enter): const _NextIntent(),
        LogicalKeySet(LogicalKeyboardKey.numpadEnter): const _NextIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _NextIntent:
              CallbackAction<_NextIntent>(onInvoke: (_) => _checkOrNext()),
        },
        child: Focus(
          autofocus: true,
          child: Builder(builder: (context) {
            final isMobilePlatform = !kIsWeb &&
                (defaultTargetPlatform == TargetPlatform.android ||
                    defaultTargetPlatform == TargetPlatform.iOS);
            final isSmallScreen = MediaQuery.of(context).size.width < 600;
            final isMobile = isMobilePlatform || isSmallScreen;

            return Scaffold(
              appBar: AppBar(
                  title: Text(
                      '${widget.mode} (${index + 1}/${quizItems.length})')),
              body: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                        value: (index + 1) / quizItems.length.toDouble()),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(q.toString(),
                            style: const TextStyle(fontSize: 20)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ctrl,
                      decoration: const InputDecoration(labelText: '解答を入力'),
                      onSubmitted: (_) => _checkOrNext(),
                      textInputAction: TextInputAction.done,
                    ),
                    const SizedBox(height: 12),
                    if (!isMobile)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton(
                            onPressed: _checkOrNext,
                            child: Text(
                                !checkedCurrent
                                    ? '解答を確認'
                                    : (index < quizItems.length - 1
                                        ? '次へ'
                                        : '結果を見る'),
                                style: const TextStyle(fontSize: 18)),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(feedback, style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 56),
                  ],
                ),
              ),
              bottomNavigationBar: isMobile
                  ? SafeArea(
                      minimum: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: SizedBox(
                        height: 56,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8))),
                          onPressed: _checkOrNext,
                          child: Text(
                              !checkedCurrent
                                  ? '解答を確認'
                                  : (index < quizItems.length - 1
                                      ? '次へ'
                                      : '結果を見る'),
                              style: const TextStyle(fontSize: 18)),
                        ),
                      ),
                    )
                  : null,
            );
          }),
        ),
      ),
    );
  }
}
