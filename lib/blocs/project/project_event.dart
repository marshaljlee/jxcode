import 'package:equatable/equatable.dart';

import '../../models/project.dart';

sealed class ProjectEvent extends Equatable {
  const ProjectEvent();

  @override
  List<Object?> get props => [];
}

class LoadProjects extends ProjectEvent {
  const LoadProjects();
}

class AddProject extends ProjectEvent {
  final String name;
  final String path;

  const AddProject({required this.name, required this.path});

  @override
  List<Object?> get props => [name, path];
}

class SelectProject extends ProjectEvent {
  final Project project;

  const SelectProject({required this.project});

  @override
  List<Object?> get props => [project];
}

class DeleteProject extends ProjectEvent {
  final Project project;

  const DeleteProject({required this.project});

  @override
  List<Object?> get props => [project];
}
