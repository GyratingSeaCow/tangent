// SPDX-License-Identifier: AGPL-3.0-or-later
/// Typed exception for HTTP API errors.
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  @override
  String toString() => 'ApiException($statusCode $code): $message';
}