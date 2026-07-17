import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/project.dart';

/// Persistent registry of JXCODE projects.
///
/// Projects are stored as a single `projects.json` file in the app
/// support directory, with each project backed by a named subdirectory
/// for session and configuration data.
class ProjectRepository {
  final String Function()? basePathOverride;
  static const _uuid = Uuid();

  ProjectRepository({this.basePathOverride});

  /// Resolves the storage directory used for the project registry file.
  Future<Directory> _appDir() async {
    if (basePathOverride != null) {
      final dir = Directory(basePathOverride!());
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final appDir = await getApplicationSupportDirectory();
    return appDir;
  }

  File _registryFile(String appPath) => File(p.join(appPath, 'projects.json'));

  /// Returns every registered project, sorted by last-opened descending.
  Future<List<Project>> getProjects() async {
    final appDir = await _appDir();
    final file = _registryFile(appDir.path);
    if (!await file.exists()) return [];

    try {
      final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
      return raw
          .map((e) => _fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    } catch (_) {
      return [];
    }
  }

  /// Alias used by existing callers.
  Future<List<Project>> list() => getProjects();

  /// Returns a single project by [id], or `null` if not found.
  Future<Project?> get(String id) async {
    final projects = await getProjects();
    try {
      return projects.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Creates a new project entry.
  ///
  /// [name] is a human-readable label, [path] is the filesystem path
  /// to the project directory, and [claudeMdPath] (optional) points to
  /// a CLAUDE.md file for that project.
  Future<Project> create(
    String name,
    String path, {
    String? claudeMdPath,
  }) async {
    final now = DateTime.now();
    final project = Project(
      id: _uuid.v4(),
      name: name,
      path: path,
      createdAt: now,
      lastOpenedAt: now,
      claudeMdPath: claudeMdPath,
    );

    final projects = await getProjects();
    projects.add(project);
    await _persist(projects);
    return project;
  }

  /// Alias used by existing callers.
  Future<Project> addProject(String name, String path) =>
      create(name, path);

  /// Replaces an existing project's fields in-place.
  ///
  /// Matching is done by [Project.id]. Throws if no project with that
  /// [id] is found.
  Future<void> update(Project updated) async {
    final projects = await getProjects();
    final idx = projects.indexWhere((p) => p.id == updated.id);
    if (idx == -1) {
      throw StateError('Project with id "${updated.id}" not found');
    }
    projects[idx] = updated;
    await _persist(projects);
  }

  /// Deletes a project and its persisted sessions.
  Future<void> deleteProject(String id) async {
    final projects = await getProjects();
    projects.removeWhere((p) => p.id == id);
    await _persist(projects);

    // Clean up session data for the removed project.
    final appDir = await _appDir();
    final sessionDir = Directory(p.join(appDir.path, 'sessions', id));
    if (await sessionDir.exists()) {
      await sessionDir.delete(recursive: true);
    }
  }

  /// Alias used by existing callers.
  Future<void> delete(String id) => deleteProject(id);

  /// Sets [lastOpenedAt] to now for the given project [id].
  Future<void> updateLastOpened(String id) async {
    final project = await get(id);
    if (project == null) return;
    await update(project.copyWith(lastOpenedAt: DateTime.now()));
  }

  /// Ensures the project registry exists (safe to call on every launch).
  Future<void> ensureInitialized() async {
    final appDir = await _appDir();
    final file = _registryFile(appDir.path);
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      await file.writeAsString('[]');
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers
  // ---------------------------------------------------------------------------

  Future<void> _persist(List<Project> projects) async {
    final appDir = await _appDir();
    final file = _registryFile(appDir.path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        projects.map(_toJson).toList(),
      ),
    );
  }

  static Map<String, dynamic> _toJson(Project p) => {
    'id': p.id,
    'name': p.name,
    'path': p.path,
    'created_at': p.createdAt.millisecondsSinceEpoch,
    'last_opened_at': p.lastOpenedAt.millisecondsSinceEpoch,
    if (p.claudeMdPath != null) 'claude_md_path': p.claudeMdPath,
  };

  static Project _fromJson(Map<String, dynamic> json) => Project(
    id: json['id'] as String,
    name: json['name'] as String,
    path: json['path'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['created_at'] as num).toInt(),
    ),
    lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['last_opened_at'] as num).toInt(),
    ),
    claudeMdPath: json['claude_md_path'] as String?,
  );
}
