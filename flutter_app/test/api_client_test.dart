import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobilecomfy/api_client.dart';

void main() {
  // /view and /ws live at the tunnel root; /lazycomfy/api/* under the app
  // path. Getting this wrong means blank images or a dead socket.
  test('viewUrl resolves at the tunnel root, not under /lazycomfy', () {
    final api = LazyApi('https://example.com/lazycomfy');
    expect(
      api.viewUrl(filename: 'a.png', subfolder: 's', type: 'output'),
      'https://example.com/view?filename=a.png&subfolder=s&type=output',
    );
    api.close();
  });

  test('thumbUrl stays under the endpoint api path', () {
    final api = LazyApi('https://example.com/lazycomfy');
    expect(
      api.thumbUrl(filename: 'a.png', type: 'output', size: 128),
      'https://example.com/lazycomfy/api/thumb?filename=a.png&type=output&s=128',
    );
    api.close();
  });

  test('endpoint without subpath still routes correctly', () {
    final api = LazyApi('http://192.168.1.2:8188/lazycomfy');
    expect(api.viewUrl(filename: 'a.png'), contains('/view?filename=a.png'));
    expect(api.thumbUrl(filename: 'a.png'), contains('/lazycomfy/api/thumb?'));
    api.close();
  });

  test('nested backend errors surface their message', () async {
    final api = LazyApi('https://example.com/lazycomfy', MockClient((req) async {
      return http.Response(
        json.encode({
          'error': {'type': 'already_downloaded', 'message': "'model.gguf' is already installed"}
        }),
        400,
        headers: {'content-type': 'application/json'},
      );
    }));
    await expectLater(
      api.config(),
      throwsA(isA<ApiException>()
          .having((e) => e.message, 'message', "'model.gguf' is already installed")
          .having((e) => e.status, 'status', 400)),
    );
    api.close();
  });

  test('proxy HTML errors get a readable message', () async {
    final api = LazyApi('https://example.com/lazycomfy', MockClient((req) async {
      return http.Response('<html><body>Gateway Timeout</body></html>', 504,
          headers: {'content-type': 'text/html'});
    }));
    await expectLater(
      api.config(),
      throwsA(isA<ApiException>()
          .having((e) => e.message, 'message', contains('not responding (HTTP 504)'))),
    );
    api.close();
  });

  test('llmGenerate surfaces the backend error envelope', () async {
    final api = LazyApi('https://example.com/lazycomfy', MockClient((req) async {
      return http.Response(
        json.encode({
          'error': {'type': 'llm_load_failed', 'message': 'llama-server did not become ready'}
        }),
        400,
        headers: {'content-type': 'application/json'},
      );
    }));
    await expectLater(
      api.llmGenerate({'mode': 'enhance', 'model': 'm.gguf'}, (_) {}),
      throwsA(isA<ApiException>().having(
          (e) => e.message, 'message', 'llama-server did not become ready')),
    );
    api.close();
  });

  test('llmGenerate rejects a stream that ends before done', () async {
    final api = LazyApi('https://example.com/lazycomfy', MockClient((req) async {
      return http.Response('data: {"type":"chunk","text":"hi"}\n\n', 200,
          headers: {'content-type': 'text/event-stream'});
    }));
    await expectLater(
      api.llmGenerate({'mode': 'enhance', 'model': 'm.gguf'}, (_) {}),
      throwsA(isA<ApiException>()
          .having((e) => e.message, 'message', contains('ended before it finished'))),
    );
    api.close();
  });
}
