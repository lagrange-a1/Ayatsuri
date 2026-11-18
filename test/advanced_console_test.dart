import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/data/endpoints.dart';
import 'package:ayatsuri/settings/advanced_console.dart';

class _StubAdapter implements HttpClientAdapter {
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('advanced console previews and sends through the shared client', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = _StubAdapter();
    final api = MihomoAPI(dio: Dio()..httpClientAdapter = adapter);
    await tester.pumpWidget(MaterialApp(home: AdvancedConsole(api: api)));

    SelectableText preview() => tester.widget<SelectableText>(
      find.byKey(const ValueKey('advanced-preview')),
    );
    expect(preview().data, contains('curl -X GET'));
    expect(preview().data, contains('/version'));

    await tester.tap(find.byKey(const ValueKey('advanced-method-POST')));
    await tester.pump();
    expect(preview().data, contains('curl -X POST'));
    expect(find.byKey(const ValueKey('advanced-body')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('advanced-send')));
    await tester.pumpAndSettle();

    expect(adapter.last, isNotNull);
    expect(adapter.last!.method, 'POST');
    expect(adapter.last!.path, '/version');
    expect(find.byKey(const ValueKey('advanced-status')), findsOneWidget);
    expect(find.byKey(const ValueKey('advanced-response')), findsOneWidget);
  });

  test('requestRaw stays scoped to the controller', () {
    final api = MihomoAPI(dio: Dio()..httpClientAdapter = _StubAdapter());
    expect(
      () => api.requestRaw('GET', 'http://example.com'),
      throwsArgumentError,
    );
    expect(() => api.requestRaw('TRACE', '/version'), throwsArgumentError);
    expect(api.requestRaw('GET', 'version'), isA<Future<dynamic>>());
  });
}
