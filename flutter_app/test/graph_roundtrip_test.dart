import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/graph.dart';

void main() {
  test('graph survives a persist round-trip with edits', () {
    final src = {
      'nodes': [
        {
          'id': 3,
          'type': 'KSampler',
          'title': 'Sampler',
          'inputs': [],
          'outputs': [],
          'widgets_values': [1, 'fixed', 20, 7.0],
        },
        {
          'id': 8,
          'type': 'CLIPTextEncode',
          'widgets_values': ['hello'],
        },
      ],
      'links': [],
    };
    final g = Graph.fromJson(Map<String, dynamic>.from(src));
    // Simulate a widget edit, as _writePositional does.
    g.nodes[0] = GraphNode(
      id: g.nodes[0].id,
      type: g.nodes[0].type,
      title: g.nodes[0].title,
      inputs: g.nodes[0].inputs,
      outputs: g.nodes[0].outputs,
      widgetsValues: [42, 'fixed', 20, 7.0],
    );
    final back = Graph.fromJson(g.toJson());
    expect(back.nodes.length, 2);
    expect((back.nodes[0].widgetsValues as List)[0], 42);
    expect(back.nodes[0].title, 'Sampler');
    expect((back.nodes[1].widgetsValues as List)[0], 'hello');
    expect(isGraphFormat(g.toJson()), true);
  });
}
