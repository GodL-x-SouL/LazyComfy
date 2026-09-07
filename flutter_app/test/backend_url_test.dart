import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/main.dart';

void main() {
  test('adds the LazyComfy route to a host URL', () {
    expect(
      normalizeBackendUrl('https://demo.trycloudflare.com'),
      'https://demo.trycloudflare.com/lazycomfy',
    );
  });

  test('does not duplicate an existing LazyComfy route', () {
    expect(
      normalizeBackendUrl('http://127.0.0.1:8188/lazycomfy/'),
      'http://127.0.0.1:8188/lazycomfy',
    );
  });

  test('rejects empty and unsupported URLs', () {
    expect(() => normalizeBackendUrl(''), throwsA(isA<BackendUrlException>()));
    expect(() => normalizeBackendUrl('ftp://example.com'),
        throwsA(isA<BackendUrlException>()));
  });
}
