import 'package:meta/meta.dart';

/// Three-state health for the Ollama daemon, surfaced as the
/// Settings → LLM status dot (§11 item 6).
///
///  - [up]               daemon reachable AND configured model is
///                       installed locally.
///  - [upModelMissing]   daemon reachable but the configured model
///                       is NOT in `/api/tags` — UI renders a
///                       copyable `ollama pull qwen3:1.7b` hint.
///  - [down]             daemon unreachable (refused / timeout /
///                       unknown) — UI nudges the user to start it.
enum OllamaHealthStatus { up, upModelMissing, down }

/// Result envelope from `OllamaBackend.health()`. `detail` carries
/// the user-facing reason for non-`up` states (e.g. `'connection
/// refused'`, `'model "qwen3:1.7b" not pulled'`).
@immutable
class OllamaHealth {
  final OllamaHealthStatus status;
  final String? detail;

  const OllamaHealth({required this.status, this.detail});

  /// Convenience for `status == up`.
  bool get isUp => status == OllamaHealthStatus.up;

  /// Convenience for `status == upModelMissing` — used by the
  /// Settings row to decide whether to render the pull hint.
  bool get isModelMissing => status == OllamaHealthStatus.upModelMissing;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OllamaHealth &&
          other.status == status &&
          other.detail == detail);

  @override
  int get hashCode => Object.hash(status, detail);

  @override
  String toString() => 'OllamaHealth(${status.name}'
      '${detail == null ? '' : ', $detail'})';
}
