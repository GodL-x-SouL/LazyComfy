import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/ui_kit.dart';

void main() {
  test('known classes get friendly words', () {
    expect(nodeDisplayName('UNETLoader'), 'Loading model');
    expect(nodeDisplayName('CLIPTextEncode'), 'Encoding prompt');
    expect(nodeDisplayName('VAEDecodeTiled'), 'Decoding image');
    expect(nodeDisplayName('SaveImage'), 'Saving');
    expect(nodeDisplayName('KSampler', 'KSampler'), 'Sampling');
  });

  test('registry display name wins when present', () {
    expect(nodeDisplayName('CheckpointLoaderSimple', 'Load Checkpoint'),
        'Load Checkpoint');
  });

  test('unknown classes fall back to spaced words', () {
    expect(nodeDisplayName('ImageUpscaleWithModel'), 'Upscaling');
    expect(nodeDisplayName('SomeCustomNodeXYZ'), 'Some Custom Node XYZ');
  });
}
