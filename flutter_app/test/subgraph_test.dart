import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/graph.dart';

void main() {
  final sub = <String, dynamic>{
    'id': 'sub-1',
    'name': 'Test Subgraph',
    'inputNode': {'id': -10},
    'inputs': [
      {'name': 'text', 'type': 'STRING', 'label': 'prompt'},
      {'name': 'width', 'type': 'INT'},
    ],
    'nodes': [
      {
        'id': 1,
        'type': 'CLIPTextEncode',
        'inputs': [
          {
            'name': 'text',
            'type': 'STRING',
            'widget': {'name': 'text'},
            'link': 1
          },
          {'name': 'clip', 'type': 'CLIP', 'link': null},
        ],
        'widgets_values': ['hello'],
      },
      {
        'id': 2,
        'type': 'EmptyLatentImage',
        'inputs': [
          {
            'name': 'width',
            'type': 'INT',
            'widget': {'name': 'width'},
            'link': 2
          },
          {
            'name': 'height',
            'type': 'INT',
            'widget': {'name': 'height'},
            'link': null
          },
        ],
        'widgets_values': [512, 512],
      },
    ],
    'links': [
      {
        'id': 1,
        'origin_id': -10,
        'origin_slot': 0,
        'target_id': 1,
        'target_slot': 0,
        'type': 'STRING'
      },
      {
        'id': 2,
        'origin_id': -10,
        'origin_slot': 1,
        'target_id': 2,
        'target_slot': 0,
        'type': 'INT'
      },
    ],
  };

  final info = <String, dynamic>{
    'CLIPTextEncode': {
      'input': {
        'required': {
          'text': [
            'STRING',
            {'multiline': true}
          ],
          'clip': ['CLIP', {}],
        },
      },
    },
    'EmptyLatentImage': {
      'input': {
        'required': {
          'width': [
            'INT',
            {'default': 512}
          ],
          'height': [
            'INT',
            {'default': 512}
          ],
        },
      },
    },
  };

  GraphNode placeholder(String text, num width) => GraphNode(
        id: 57,
        type: 'sub-1',
        inputs: [
          {
            'name': 'text',
            'type': 'STRING',
            'widget': {'name': 'text'},
            'link': null
          },
        ],
        outputs: [
          {'name': 'IMAGE', 'type': 'IMAGE'},
        ],
        widgetsValues: [text, width],
        widgetsValuesNamed: {'text': text, 'width': width},
      );

  Graph workflow(GraphNode node) => Graph(
        nodes: [node],
        links: const [],
        subgraphs: [sub],
      );

  test('subgraph boundaries become widgets with inner schemas', () {
    final node = placeholder('hello', 512);
    final slots = subgraphWidgetSlots(sub, info, node);
    expect(slots.map((s) => s.name), ['text', 'width']);
    expect(slots[0].kind, 'text');
    expect(slots[0].label, 'prompt');
    expect(slots[0].multiline, true);
    expect(slots[1].kind, 'number');
    final res = resolveWidgets(node, slots);
    expect(res.items.map((i) => i.index), [0, 1]);
  });

  test('subgraph boundary values feed expanded prompt nodes', () {
    final result = buildPrompt(workflow(placeholder('a cat', 768)), {}, info);
    expect(result.errors, isEmpty);
    expect(result.prompt.length, 2);
    final ops =
        result.prompt.values.map((v) => (v as Map)['class_type']).toList();
    expect(ops, containsAll(['CLIPTextEncode', 'EmptyLatentImage']));
    final text = result.prompt.values
        .firstWhere((v) => (v as Map)['class_type'] == 'CLIPTextEncode') as Map;
    final latent = result.prompt.values
            .firstWhere((v) => (v as Map)['class_type'] == 'EmptyLatentImage')
        as Map;
    expect((text['inputs'] as Map)['text'], 'a cat');
    expect((latent['inputs'] as Map)['width'], 768);
  });
}
