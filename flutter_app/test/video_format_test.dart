import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/native_video.dart';

void main() {
  test('playable containers go to ExoPlayer, stills render as image', () {
    for (final n in ['a.mp4', 'b.MP4', 'c.webm', 'd.mkv', 'e.mov', 'f.m4v', 'g.3gp']) {
      expect(isPlayableVideo(n), true, reason: n);
    }
    for (final n in ['a.gif', 'b.png', 'c.jpg', 'd.jpeg', 'e.webp', 'noext']) {
      expect(isPlayableVideo(n), false, reason: n);
    }
  });
}
