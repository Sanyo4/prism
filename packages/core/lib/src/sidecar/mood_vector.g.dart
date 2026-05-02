// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'mood_vector.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MoodVector _$MoodVectorFromJson(Map<String, dynamic> json) => MoodVector(
  happy: (json['happy'] as num).toDouble(),
  sad: (json['sad'] as num).toDouble(),
  aggressive: (json['aggressive'] as num).toDouble(),
  relaxed: (json['relaxed'] as num).toDouble(),
  party: (json['party'] as num).toDouble(),
);

Map<String, dynamic> _$MoodVectorToJson(MoodVector instance) =>
    <String, dynamic>{
      'happy': instance.happy,
      'sad': instance.sad,
      'aggressive': instance.aggressive,
      'relaxed': instance.relaxed,
      'party': instance.party,
    };
