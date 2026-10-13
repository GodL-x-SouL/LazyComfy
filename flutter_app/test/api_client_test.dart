import 'package:flutter_test/flutter_test.dart';
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
}
