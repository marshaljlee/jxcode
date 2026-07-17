import 'package:flutter_bloc/flutter_bloc.dart';

import '../../services/project_repository.dart';
import 'project_event.dart';
import 'project_state.dart';

class ProjectBloc extends Bloc<ProjectEvent, ProjectState> {
  final ProjectRepository _repository;

  ProjectBloc({required this._repository})
      : super(const ProjectState()) {
    on<LoadProjects>(_onLoadProjects);
    on<AddProject>(_onAddProject);
    on<SelectProject>(_onSelectProject);
    on<DeleteProject>(_onDeleteProject);
  }

  Future<void> _onLoadProjects(
    LoadProjects event,
    Emitter<ProjectState> emit,
  ) async {
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final projects = await _repository.getProjects();
      emit(state.copyWith(projects: projects, isLoading: false));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Failed to load projects: $e',
      ));
    }
  }

  Future<void> _onAddProject(
    AddProject event,
    Emitter<ProjectState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));
    try {
      final project =
          await _repository.addProject(event.name, event.path);
      final projects = [...state.projects, project];
      emit(state.copyWith(
        projects: projects,
        selectedProject: project,
        isLoading: false,
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Failed to add project: $e',
      ));
    }
  }

  void _onSelectProject(
    SelectProject event,
    Emitter<ProjectState> emit,
  ) {
    emit(state.copyWith(selectedProject: event.project));
  }

  Future<void> _onDeleteProject(
    DeleteProject event,
    Emitter<ProjectState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));
    try {
      await _repository.deleteProject(event.project.id);
      final projects = state.projects
          .where((p) => p.id != event.project.id)
          .toList();
      final selected = state.selectedProject?.id == event.project.id
          ? null
          : state.selectedProject;
      emit(state.copyWith(
        projects: projects,
        selectedProject: selected,
        isLoading: false,
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Failed to delete project: $e',
      ));
    }
  }
}
