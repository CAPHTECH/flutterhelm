import 'dart:convert';
import 'dart:io';

const String _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9xS8gAAAAASUVORK5CYII=';

void main() {
  final provider = _FakeAdapterProvider();
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(provider.handleLine);
}

class _FakeAdapterProvider {
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
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) {
      return;
    }
    final id = decoded['id'];
    final method = decoded['method'] as String?;
    if (id == null || method == null) {
      return;
    }
    final params = _asMap(decoded['params']);
    switch (method) {
      case 'initialize':
        _sendResult(id, <String, Object?>{
          'adapterProtocolVersion': 'flutterhelm.adapter.v1',
          'providerInfo': <String, Object?>{
            'name': 'fake-stdio-adapter-provider',
            'version': '0.1.0',
          },
          'families': <String>['runtimeDriver'],
          'operations': <String, Object?>{
            'runtimeDriver': <String>[
              'list_elements',
              'tap',
              'enter_text',
              'scroll_until_visible',
              'capture_screenshot',
            ],
          },
        });
        return;
      case 'provider/health':
        _sendResult(id, <String, Object?>{
          'providerInfo': <String, Object?>{
            'name': 'fake-stdio-adapter-provider',
            'version': '0.1.0',
          },
          'families': <String, Object?>{
            'runtimeDriver': <String, Object?>{
              'healthy': true,
              'operations': <String>[
                'list_elements',
                'tap',
                'enter_text',
                'scroll_until_visible',
                'capture_screenshot',
              ],
              'supportedPlatforms': <String>['ios'],
              'supportedLocatorFields': <String>[
                'text',
                'textContains',
                'label',
                'labelContains',
                'valueKey',
                'type',
                'index',
                'visibleOnly',
              ],
              'screenshotFormats': <String>['png', 'jpg', 'jpeg'],
            },
          },
        });
        return;
      case 'provider/invoke':
        _handleInvoke(id, params);
        return;
      default:
        _sendError(id, 'Unsupported method: $method');
        return;
    }
  }

  void _handleInvoke(Object id, Map<String, Object?> params) {
    final family = params['family'] as String?;
    final operation = params['operation'] as String?;
    final input = _asMap(params['input']);
    if (family != 'runtimeDriver' || operation == null) {
      _sendError(id, 'Unsupported adapter family.');
      return;
    }
    switch (operation) {
      case 'list_elements':
        _sendResult(id, <String, Object?>{'elements': _elements()});
        return;
      case 'tap':
        _handleTap(_asDouble(input['x']) ?? 0, _asDouble(input['y']) ?? 0);
        _sendResult(id, <String, Object?>{'status': 'ok'});
        return;
      case 'enter_text':
        final text = input['text'] as String? ?? '';
        final submit = input['submit'] as bool? ?? false;
        if (_focusedTextField && submit) {
          _submittedText = text;
        }
        _sendResult(
          id,
          <String, Object?>{
            'status': 'ok',
            'textLength': text.length,
            'submitted': submit,
          },
        );
        return;
      case 'scroll_until_visible':
        _deepItemVisible = true;
        _sendResult(id, <String, Object?>{'status': 'ok'});
        return;
      case 'capture_screenshot':
        final saveTo = input['saveTo'] as String?;
        if (saveTo == null || saveTo.isEmpty) {
          _sendError(id, 'saveTo is required.');
          return;
        }
        final file = File(saveTo);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(base64Decode(_onePixelPngBase64));
        _sendResult(
          id,
          <String, Object?>{
            'status': 'ok',
            'path': saveTo,
          },
        );
        return;
      default:
        _sendError(id, 'Unsupported operation: $operation');
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
