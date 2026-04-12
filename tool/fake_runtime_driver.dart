import 'dart:convert';
import 'dart:io';

const String _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9xS8gAAAAASUVORK5CYII=';

void main() {
  final driver = _FakeRuntimeDriver();
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(driver.handleLine);
}

class _FakeRuntimeDriver {
  bool _tapped = false;
  bool _deepItemVisible = false;
  bool _deepItemTapped = false;
  bool _focusedTextField = false;
  String? _submittedText;

  void handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final message = jsonDecode(trimmed);
    if (message is! Map) {
      return;
    }
    final id = message['id'];
    final method = message['method'] as String?;
    if (id == null || method == null) {
      return;
    }
    switch (method) {
      case 'initialize':
        _sendResult(id, <String, Object?>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{
            'tools': <String, Object?>{'listChanged': false},
          },
          'serverInfo': <String, Object?>{
            'name': 'flutterhelm-fake-runtime-driver',
            'version': '0.1.0',
          },
        });
        return;
      case 'tools/list':
        _sendResult(id, <String, Object?>{
          'tools': <Map<String, Object?>>[
            _tool('mobile_list_available_devices'),
            _tool('mobile_list_elements_on_screen'),
            _tool('mobile_click_on_screen_at_coordinates'),
            _tool('mobile_type_keys'),
            _tool('mobile_swipe_on_screen'),
            _tool('mobile_save_screenshot'),
          ],
        });
        return;
      case 'tools/call':
        final params = _asMap(message['params']);
        final toolName = params['name'] as String?;
        final arguments = _asMap(params['arguments']);
        if (toolName == null) {
          _sendToolError(id, 'Missing tool name');
          return;
        }
        _handleToolCall(id, toolName, arguments);
        return;
      default:
        _sendError(id, 'Unsupported method: $method');
        return;
    }
  }

  void _handleToolCall(Object id, String toolName, Map<String, Object?> arguments) {
    switch (toolName) {
      case 'mobile_list_available_devices':
        _sendToolResult(
          id,
          <String, Object?>{
            'devices': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'fake-ios-simulator',
                'name': 'Fake iPhone',
                'platform': 'ios',
                'type': 'simulator',
                'version': '18.0',
                'state': 'online',
              },
            ],
          },
        );
        return;
      case 'mobile_list_elements_on_screen':
        _sendToolResult(id, <String, Object?>{'elements': _elements()});
        return;
      case 'mobile_click_on_screen_at_coordinates':
        final x = _asDouble(arguments['x']) ?? 0;
        final y = _asDouble(arguments['y']) ?? 0;
        _handleTap(x, y);
        _sendToolResult(id, <String, Object?>{'status': 'ok'});
        return;
      case 'mobile_type_keys':
        final text = arguments['text'] as String? ?? '';
        final submit = arguments['submit'] as bool? ?? false;
        if (_focusedTextField) {
          if (submit) {
            _submittedText = text;
          }
        }
        _sendToolResult(
          id,
          <String, Object?>{
            'status': 'ok',
            'textLength': text.length,
            'submitted': submit,
          },
        );
        return;
      case 'mobile_swipe_on_screen':
        final direction = arguments['direction'] as String? ?? 'down';
        if (direction == 'up' || direction == 'down') {
          _deepItemVisible = true;
        }
        _sendToolResult(
          id,
          <String, Object?>{
            'status': 'ok',
            'direction': direction,
          },
        );
        return;
      case 'mobile_save_screenshot':
        final saveTo = arguments['saveTo'] as String?;
        if (saveTo == null || saveTo.isEmpty) {
          _sendToolError(id, 'Missing saveTo path');
          return;
        }
        final file = File(saveTo);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(base64Decode(_onePixelPngBase64));
        _sendToolResult(
          id,
          <String, Object?>{
            'status': 'ok',
            'path': saveTo,
          },
        );
        return;
      default:
        _sendToolError(id, 'Unsupported tool: $toolName');
        return;
    }
  }

  List<Map<String, Object?>> _elements() {
    return <Map<String, Object?>>[
      <String, Object?>{
        'text': 'Tap primary',
        'label': 'Tap primary',
        'valueKey': 'primaryButton',
        'type': 'ElevatedButton',
        'visible': true,
        'x': 120,
        'y': 140,
      },
      <String, Object?>{
        'text': 'Name input',
        'label': 'Name input',
        'valueKey': 'nameField',
        'type': 'TextField',
        'visible': true,
        'x': 120,
        'y': 220,
      },
      <String, Object?>{
        'text': _tapped ? 'Status: tapped' : 'Status: idle',
        'label': 'Status label',
        'valueKey': 'statusLabel',
        'type': 'Text',
        'visible': true,
        'x': 120,
        'y': 300,
      },
      <String, Object?>{
        'text': _submittedText == null
            ? 'Submission pending'
            : 'Submitted: $_submittedText',
        'label': 'Submission label',
        'valueKey': 'submissionLabel',
        'type': 'Text',
        'visible': true,
        'x': 120,
        'y': 340,
      },
      <String, Object?>{
        'text': 'Deep action',
        'label': 'Deep action',
        'valueKey': 'deepItem',
        'type': 'ListTile',
        'visible': _deepItemVisible,
        'x': 120,
        'y': 760,
      },
      <String, Object?>{
        'text': _deepItemTapped ? 'Deep action tapped' : 'Deep action pending',
        'label': 'Deep action status',
        'valueKey': 'deepStatus',
        'type': 'Text',
        'visible': true,
        'x': 120,
        'y': 820,
      },
    ];
  }

  void _handleTap(double x, double y) {
    if ((x - 120).abs() <= 40 && (y - 140).abs() <= 40) {
      _tapped = !_tapped;
      _focusedTextField = false;
      return;
    }
    if ((x - 120).abs() <= 40 && (y - 220).abs() <= 40) {
      _focusedTextField = true;
      return;
    }
    if (_deepItemVisible && (x - 120).abs() <= 40 && (y - 760).abs() <= 40) {
      _deepItemTapped = true;
    }
  }

  Map<String, Object?> _tool(String name) {
    return <String, Object?>{
      'name': name,
      'description': name,
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      },
    };
  }

  void _sendResult(Object id, Map<String, Object?> result) {
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      }),
    );
  }

  void _sendError(Object id, String message) {
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{
          'code': -32601,
          'message': message,
        },
      }),
    );
  }

  void _sendToolError(Object id, String message) {
    _sendResult(id, <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': message},
      ],
      'isError': true,
    });
  }

  void _sendToolResult(Object id, Map<String, Object?> payload) {
    _sendResult(id, <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': jsonEncode(payload)},
      ],
    });
  }

  Map<String, Object?> _asMap(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? key, Object? nested) =>
            MapEntry<String, Object?>(key.toString(), nested),
      );
    }
    return <String, Object?>{};
  }

  double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }
}
