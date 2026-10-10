import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/main.dart';

void main() {
  test('image inputs stay image-only', () {
    expect(
      uploadExtensionsForAcceptTypes(['image/png', 'image/jpeg', 'image/webp']),
      ['png', 'jpg', 'jpeg', 'webp'],
    );
  });

  test('workflow loader accepts json', () {
    expect(
      uploadExtensionsForAcceptTypes(['.json', 'application/json']),
      ['json'],
    );
  });

  test('node media inputs accept images and video', () {
    expect(
      uploadExtensionsForAcceptTypes(['image/*', 'video/*']),
      ['png', 'jpg', 'jpeg', 'webp', 'mp4', 'mov', 'webm', 'mkv', 'm4v'],
    );
  });

  test('inputs without an accept list are unrestricted', () {
    expect(uploadExtensionsForAcceptTypes([]), isNull);
  });

  test('view links with a filename are downloads', () {
    expect(
      isDownloadUrl('https://demo.trycloudflare.com/view?filename=a.png&subfolder=&type=output'),
      isTrue,
    );
  });

  test('app pages are not downloads', () {
    expect(isDownloadUrl('https://demo.trycloudflare.com/lazycomfy'), isFalse);
    expect(
      isDownloadUrl('https://demo.trycloudflare.com/lazycomfy/video'),
      isFalse,
    );
    expect(isDownloadUrl('not a url %%'), isFalse);
  });
}
