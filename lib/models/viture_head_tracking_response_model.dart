class HeadTrackingResponse {
  final bool status;
  final String message;
  final int code;

  HeadTrackingResponse({
    required this.status,
    required this.message,
    required this.code,
  });

  factory HeadTrackingResponse.fromJson(Map<String, dynamic> json) {
    return HeadTrackingResponse(
      status: json['status'],
      message: json['message'],
      code: json['code'],
    );
  }
}
