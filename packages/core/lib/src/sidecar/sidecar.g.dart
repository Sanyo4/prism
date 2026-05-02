// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sidecar.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Sidecar _$SidecarFromJson(Map<String, dynamic> json) => Sidecar(
  schemaVersion: (json['schema_version'] as num).toInt(),
  analyzer: json['analyzer'] as String,
  analyzerModels: (json['analyzer_models'] as List<dynamic>)
      .map((e) => e as String)
      .toList(),
  audioSha1: json['audio_sha1'] as String,
  durationSec: (json['duration_sec'] as num).toDouble(),
  sampleRate: (json['sample_rate'] as num).toInt(),
  bitDepth: (json['bit_depth'] as num?)?.toInt(),
  bpm: (json['bpm'] as num).toDouble(),
  bpmConfidence: (json['bpm_confidence'] as num).toDouble(),
  key: json['key'] as String,
  keyConfidence: (json['key_confidence'] as num).toDouble(),
  loudnessLufs: (json['loudness_lufs'] as num).toDouble(),
  replaygainTrackDb: (json['replaygain_track_db'] as num).toDouble(),
  replaygainAlbumDb: (json['replaygain_album_db'] as num).toDouble(),
  spectralCentroidMean: (json['spectral_centroid_mean'] as num).toDouble(),
  danceability: (json['danceability'] as num).toDouble(),
  mood: MoodVector.fromJson(json['mood'] as Map<String, dynamic>),
  genreTop3: Sidecar._genreTopListFromJson(json['genre_top3'] as List),
  voiceInstrumental: (json['voice_instrumental'] as num).toDouble(),
  embeddingModel: json['embedding_model'] as String,
  embedding: (json['embedding'] as List<dynamic>)
      .map((e) => (e as num).toDouble())
      .toList(),
);

Map<String, dynamic> _$SidecarToJson(Sidecar instance) => <String, dynamic>{
  'schema_version': instance.schemaVersion,
  'analyzer': instance.analyzer,
  'analyzer_models': instance.analyzerModels,
  'audio_sha1': instance.audioSha1,
  'duration_sec': instance.durationSec,
  'sample_rate': instance.sampleRate,
  'bit_depth': instance.bitDepth,
  'bpm': instance.bpm,
  'bpm_confidence': instance.bpmConfidence,
  'key': instance.key,
  'key_confidence': instance.keyConfidence,
  'loudness_lufs': instance.loudnessLufs,
  'replaygain_track_db': instance.replaygainTrackDb,
  'replaygain_album_db': instance.replaygainAlbumDb,
  'spectral_centroid_mean': instance.spectralCentroidMean,
  'danceability': instance.danceability,
  'mood': instance.mood,
  'genre_top3': Sidecar._genreTopListToJson(instance.genreTop3),
  'voice_instrumental': instance.voiceInstrumental,
  'embedding_model': instance.embeddingModel,
  'embedding': instance.embedding,
};
