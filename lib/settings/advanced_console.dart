import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/controller_presets.dart';
import '../data/endpoints.dart';

/// The last section of Settings: pick a real controller command or type a
/// raw one and send it through the same authenticated client as the rest of
/// the app. Deliberately not a separate tab — it is an escape hatch, not the
/// primary way to use the app.
class AdvancedConsole extends StatefulWidget {
  const AdvancedConsole({super.key, required this.api});

  final MihomoAPI api;

  @override
  State<AdvancedConsole> createState() => _AdvancedConsoleState();
}

class _AdvancedConsoleState extends State<AdvancedConsole> {
  static const _methods = ['GET', 'PUT', 'PATCH', 'POST', 'DELETE'];
  static const _customPreset = -1;

  late final TextEditingController _path = TextEditingController(
    text: kControllerPresets.first.path,
  );
  late final TextEditingController _body = TextEditingController(
    text: kControllerPresets.first.body,
  );
  int _preset = 0;
  String _method = kControllerPresets.first.method;
  bool _busy = false;
  int? _status;
  String? _response;
  String? _error;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  bool get _hasBody =>
      _method == 'PUT' || _method == 'PATCH' || _method == 'POST';

  ControllerPreset? get _selected =>
      _preset == _customPreset ? null : kControllerPresets[_preset];

  void _applyPreset(int? value) {
    if (value == null) return;
    setState(() {
      _preset = value;
      if (value != _customPreset) {
        final preset = kControllerPresets[value];
        _method = preset.method;
        _path.text = preset.path;
        _body.text = preset.body;
      }
      _status = null;
      _response = null;
      _error = null;
    });
  }

  Future<void> _send() async {
    if (_busy) return;
    Object? payload;
    if (_hasBody && _body.text.trim().isNotEmpty) {
      try {
        payload = jsonDecode(_body.text);
      } catch (e) {
        setState(() => _error = 'JSON: $e');
        return;
      }
    }
    setState(() {
      _busy = true;
      _status = null;
      _response = null;
      _error = null;
    });
    try {
      final response = await widget.api.requestRaw(
        _method,
        _path.text,
        data: payload,
      );
      if (!mounted) return;
      setState(() {
        _status = response.statusCode;
        _response = _formatBody(response.data);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _formatBody(dynamic data) {
    if (data == null) return '';
    if (data is String) return data;
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  @override
  void dispose() {
    _path.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zh = _zh;
    final preview = formatCurlRequest(
      baseUrl: widget.api.baseUrl,
      method: _method,
      path: _path.text,
      body: _hasBody ? _body.text : '',
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              zh ? '直接调用控制器' : 'Call the controller directly',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              zh
                  ? '选一条预设命令，或自己填方法与路径；请求只发往当前配置的 external controller。'
                  : 'Pick a preset or type your own method and path. Requests only go to the configured external controller.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('advanced-preset'),
              initialValue: _preset,
              decoration: InputDecoration(
                labelText: zh ? '预设命令' : 'Preset command',
                border: const OutlineInputBorder(),
              ),
              items: [
                ...kControllerPresets.asMap().entries.map(
                  (e) => DropdownMenuItem<int>(
                    value: e.key,
                    child: Text(e.value.label(zh)),
                  ),
                ),
                DropdownMenuItem<int>(
                  value: _customPreset,
                  child: Text(zh ? '自定义…' : 'Custom…'),
                ),
              ],
              onChanged: _applyPreset,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: _methods.map((m) {
                return ChoiceChip(
                  key: ValueKey('advanced-method-$m'),
                  label: Text(m),
                  selected: _method == m,
                  onSelected: (_) => setState(() => _method = m),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('advanced-path'),
              controller: _path,
              decoration: InputDecoration(
                labelText: zh ? '路径（相对控制器）' : 'Path (controller-relative)',
                hintText: '/configs',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_hasBody) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('advanced-body'),
                controller: _body,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: zh ? '请求体（JSON）' : 'Body (JSON)',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (_selected != null) ...[
              const SizedBox(height: 8),
              Text(
                _selected!.note(zh),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Text(
              zh ? '请求预览' : 'Request preview',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: SelectableText(
                preview,
                key: const ValueKey('advanced-preview'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('advanced-send'),
              onPressed: _busy ? null : _send,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: Text(zh ? '发送请求' : 'Send request'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                '${zh ? '失败' : 'Error'}: $_error',
                key: const ValueKey('advanced-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(
                '${zh ? '状态' : 'Status'}: $_status',
                key: const ValueKey('advanced-status'),
              ),
              const SizedBox(height: 4),
              SelectableText(
                _response ?? '',
                key: const ValueKey('advanced-response'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
