import 'package:json_annotation/json_annotation.dart';

part 'mood_vector.g.dart';

/// Five sigmoid-scored mood probabilities from MSD-musicnn's
/// classification head, mirroring slice 3's [`SidecarV1.mood`] block.
///
/// Each dimension is independent (sigmoid, not softmax) so the values
/// don't sum to 1 — high `happy` and high `relaxed` can co-occur. Slice 4
/// stores each component verbatim in flat columns on the `tracks` table
/// to keep mood/vibe SQL filters cheap.
@JsonSerializable()
class MoodVector {
  /// Probability the classifier scores the track as "happy".
  final double happy;

  /// Probability the classifier scores the track as "sad".
  final double sad;

  /// Probability the classifier scores the track as "aggressive".
  final double aggressive;

  /// Probability the classifier scores the track as "relaxed".
  final double relaxed;

  /// Probability the classifier scores the track as "party".
  final double party;

  const MoodVector({
    required this.happy,
    required this.sad,
    required this.aggressive,
    required this.relaxed,
    required this.party,
  });

  factory MoodVector.fromJson(Map<String, dynamic> json) =>
      _$MoodVectorFromJson(json);
  Map<String, dynamic> toJson() => _$MoodVectorToJson(this);
}
