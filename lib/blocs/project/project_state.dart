import '../../models/project.dart';

class ProjectState {
  final List<Project> projects;
  final Project? selectedProject;
  final bool isLoading;
  final String? error;

  const ProjectState({
    this.projects = const [],
    this.selectedProject,
    this.isLoading = false,
    this.error,
  });

  ProjectState copyWith({
    List<Project>? projects,
    Project? selectedProject,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return ProjectState(
      projects: projects ?? this.projects,
      selectedProject: selectedProject ?? this.selectedProject,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
