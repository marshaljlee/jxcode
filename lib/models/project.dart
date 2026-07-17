import 'package:equatable/equatable.dart';

class Project extends Equatable {
  final String id;
  final String name;
  final String path;
  final DateTime createdAt;
  final DateTime lastOpenedAt;
  final String? claudeMdPath;

  const Project({
    required this.id,
    required this.name,
    required this.path,
    required this.createdAt,
    required this.lastOpenedAt,
    this.claudeMdPath,
  });

  Project copyWith({
    String? id,
    String? name,
    String? path,
    DateTime? createdAt,
    DateTime? lastOpenedAt,
    String? claudeMdPath,
  }) {
    return Project(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      createdAt: createdAt ?? this.createdAt,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      claudeMdPath: claudeMdPath ?? this.claudeMdPath,
    );
  }

  @override
  List<Object?> get props => [id, name, path, createdAt, lastOpenedAt, claudeMdPath];
}
