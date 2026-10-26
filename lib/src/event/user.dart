import 'dart:convert';
import 'package:crypto/crypto.dart';

class WasmWatchUser {
  const WasmWatchUser({this.id, this.email, this.username, this.emailHash});

  /// Already hashed capture-time identity from a persisted native scope.
  final String? emailHash;
  final String? id;
  final String? email;
  final String? username;

  Map<String, Object?> toJson() {
    String? emailHash = this.emailHash;
    if (email != null && email!.trim().isNotEmpty) {
      emailHash =
          sha256.convert(utf8.encode(email!.trim().toLowerCase())).toString();
    }
    return {
      if (id != null) 'id': id,
      if (username != null) 'username': username,
      if (emailHash != null) 'email_hash': emailHash,
    };
  }
}
