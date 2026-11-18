/// Preset commands for the settings "advanced" console.
///
/// Every entry maps to a real mihomo external-controller endpoint already
/// used by [MihomoAPI] in `lib/data/endpoints.dart`. This is pure data so it
/// can be unit-tested without Flutter or a live controller.
class ControllerPreset {
  const ControllerPreset({
    required this.id,
    required this.labelZh,
    required this.labelEn,
    required this.method,
    required this.path,
    this.body = '',
    required this.noteZh,
    required this.noteEn,
  });

  final String id;
  final String labelZh;
  final String labelEn;
  final String method;
  final String path;
  final String body;
  final String noteZh;
  final String noteEn;

  String label(bool zh) => zh ? labelZh : labelEn;
  String note(bool zh) => zh ? noteZh : noteEn;
}

const List<ControllerPreset> kControllerPresets = [
  ControllerPreset(
    id: 'version',
    labelZh: '核心版本',
    labelEn: 'Core version',
    method: 'GET',
    path: '/version',
    noteZh: '读取 mihomo 内核版本与元数据。',
    noteEn: 'Read the mihomo core version and build metadata.',
  ),
  ControllerPreset(
    id: 'configs',
    labelZh: '当前配置',
    labelEn: 'Current configs',
    method: 'GET',
    path: '/configs',
    noteZh: '查看当前模式、端口、TUN 与 DNS 开关等配置。',
    noteEn: 'Inspect mode, ports, TUN and DNS switches.',
  ),
  ControllerPreset(
    id: 'set-mode',
    labelZh: '切换模式',
    labelEn: 'Set mode',
    method: 'PATCH',
    path: '/configs',
    body: '{"mode":"rule"}',
    noteZh: 'mode 可选 rule / direct / global；改完立即生效。',
    noteEn: 'mode accepts rule / direct / global; applied immediately.',
  ),
  ControllerPreset(
    id: 'proxies',
    labelZh: '全部节点',
    labelEn: 'All proxies',
    method: 'GET',
    path: '/proxies',
    noteZh: '返回所有节点与策略组，响应可能很大。',
    noteEn: 'Returns every proxy and group; the payload can be large.',
  ),
  ControllerPreset(
    id: 'select-proxy',
    labelZh: '选择节点',
    labelEn: 'Select proxy',
    method: 'PUT',
    path: '/proxies/GLOBAL',
    body: '{"name":"节点名"}',
    noteZh: '把 path 里的 GLOBAL 换成策略组名，body 的 name 换成该组内节点名。',
    noteEn:
        'Replace GLOBAL in the path with a group, and name with one of its members.',
  ),
  ControllerPreset(
    id: 'groups',
    labelZh: '策略组',
    labelEn: 'Proxy groups',
    method: 'GET',
    path: '/group',
    noteZh: '查看每个策略组的 now 与候选列表。',
    noteEn: 'Inspect each group’s current node and candidates.',
  ),
  ControllerPreset(
    id: 'rules',
    labelZh: '规则列表',
    labelEn: 'Rules',
    method: 'GET',
    path: '/rules',
    noteZh: '返回当前分流规则，数量通常很多。',
    noteEn: 'Returns the routing rules; usually a long list.',
  ),
  ControllerPreset(
    id: 'connections',
    labelZh: '活动连接',
    labelEn: 'Connections',
    method: 'GET',
    path: '/connections',
    noteZh: '这是流式接口，普通 GET 会一直等待；可在下方改成短超时快照。',
    noteEn: 'This is a streaming endpoint; a plain GET waits until timeout.',
  ),
  ControllerPreset(
    id: 'close-connections',
    labelZh: '断开全部连接',
    labelEn: 'Close all connections',
    method: 'DELETE',
    path: '/connections',
    noteZh: '断开内核当前所有连接；切换节点后可能需要。',
    noteEn: 'Closes every active connection in the core.',
  ),
  ControllerPreset(
    id: 'close-connection',
    labelZh: '断开单个连接',
    labelEn: 'Close one connection',
    method: 'DELETE',
    path: '/connections/{id}',
    noteZh: '把 {id} 换成 /connections 返回的连接 ID。',
    noteEn: 'Replace {id} with an ID from /connections.',
  ),
  ControllerPreset(
    id: 'traffic',
    labelZh: '流量快照',
    labelEn: 'Traffic snapshot',
    method: 'GET',
    path: '/traffic',
    noteZh: '流式接口的单帧快照，响应可能迟迟不结束。',
    noteEn: 'One frame of the streaming traffic feed; may not complete.',
  ),
  ControllerPreset(
    id: 'memory',
    labelZh: '内存快照',
    labelEn: 'Memory snapshot',
    method: 'GET',
    path: '/memory',
    noteZh: '查看内核内存占用快照。',
    noteEn: 'Snapshot of core memory usage.',
  ),
  ControllerPreset(
    id: 'logs',
    labelZh: '日志快照',
    labelEn: 'Log snapshot',
    method: 'GET',
    path: '/logs',
    noteZh: '日志同样是流式接口，普通 GET 只拿一帧。',
    noteEn: 'Logs are streamed too; a plain GET returns one frame.',
  ),
  ControllerPreset(
    id: 'dns-query',
    labelZh: 'DNS 查询',
    labelEn: 'DNS query',
    method: 'GET',
    path: '/dns/query?name=example.com&type=A',
    noteZh: '通过内核 DNS 解析域名，可改 name 与 type。',
    noteEn: 'Resolve a name through the core DNS; edit name and type.',
  ),
  ControllerPreset(
    id: 'flush-fakeip',
    labelZh: '清空 FakeIP',
    labelEn: 'Flush FakeIP cache',
    method: 'POST',
    path: '/cache/fakeip/flush',
    noteZh: '清空内核 FakeIP 缓存。',
    noteEn: 'Clears the core FakeIP cache.',
  ),
  ControllerPreset(
    id: 'flush-dns',
    labelZh: '清空 DNS',
    labelEn: 'Flush DNS cache',
    method: 'POST',
    path: '/cache/dns/flush',
    noteZh: '清空内核 DNS 缓存。',
    noteEn: 'Clears the core DNS cache.',
  ),
  ControllerPreset(
    id: 'healthcheck',
    labelZh: '节点健康检查',
    labelEn: 'Provider health check',
    method: 'GET',
    path: '/providers/proxies/{provider}/healthcheck',
    noteZh: '把 {provider} 换成策略组里的 proxy provider 名。',
    noteEn: 'Replace {provider} with a proxy provider name.',
  ),
  ControllerPreset(
    id: 'restart',
    labelZh: '重启内核',
    labelEn: 'Restart core',
    method: 'POST',
    path: '/restart',
    body: '{"path":"","payload":""}',
    noteZh: '重启 mihomo 内核；当前连接会全部断开。',
    noteEn: 'Restarts the mihomo core; all current connections drop.',
  ),
  ControllerPreset(
    id: 'upgrade-ui',
    labelZh: '更新管理面板',
    labelEn: 'Upgrade dashboard',
    method: 'POST',
    path: '/upgrade/ui',
    noteZh: '触发内核控制面板资源更新。',
    noteEn: 'Triggers the controller dashboard assets upgrade.',
  ),
  ControllerPreset(
    id: 'gc',
    labelZh: '垃圾回收',
    labelEn: 'Garbage collect',
    method: 'PUT',
    path: '/debug/gc',
    noteZh: '需要把内核日志级别设为 debug。',
    noteEn: 'Requires the controller log level to be debug.',
  ),
];

/// Renders the request as a copy-pasteable curl command. The secret is never
/// interpolated — only a placeholder is shown, so screenshots stay safe.
String formatCurlRequest({
  required String baseUrl,
  required String method,
  required String path,
  String body = '',
}) {
  final root = baseUrl.replaceAll(RegExp(r'/+$'), '');
  final p = path.startsWith('/') ? path : '/$path';
  final lines = <String>["curl -X ${method.trim().toUpperCase()} '$root$p'"];
  if (body.trim().isNotEmpty) {
    lines.add("  -H 'Content-Type: application/json'");
    lines.add("  -d '${body.replaceAll("'", "'\\''")}'");
  }
  lines.add("  -H 'Authorization: Bearer <controller secret>'");
  return lines.join(' \\\n');
}
