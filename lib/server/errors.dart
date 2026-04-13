class FlutterHelmToolError implements Exception {
  FlutterHelmToolError({
    required this.code,
    required this.category,
    required this.message,
    required this.retryable,
    this.details,
    this.detailsResource,
  });

  final String code;
  final String category;
  final String message;
  final bool retryable;
  final Map<String, Object?>? details;
  final Map<String, Object?>? detailsResource;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'code': code,
      'category': category,
      'message': message,
      'retryable': retryable,
      if (details != null) 'details': details,
      if (detailsResource != null) 'detailsResource': detailsResource,
    };
  }

  @override
  String toString() => message;
}

class FlutterHelmProtocolError implements Exception {
  FlutterHelmProtocolError(this.code, this.message, {this.data});

  final int code;
  final String message;
  final Map<String, Object?>? data;
}
