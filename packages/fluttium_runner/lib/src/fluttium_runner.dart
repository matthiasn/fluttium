import 'dart:convert';
import 'dart:io';

import 'package:fluttium_flow/fluttium_flow.dart';
import 'package:fluttium_runner/src/bundles/bundles.dart';
import 'package:mason/mason.dart';
import 'package:path/path.dart';
import 'package:process/process.dart';
import 'package:watcher/watcher.dart';

/// {@template fluttium_runner}
/// A runner for executing Fluttium flow tests.
/// {@endtemplate}
class FluttiumRunner {
  /// {@macro fluttium_runner}
  FluttiumRunner({
    required this.flowFile,
    required this.projectDirectory,
    required this.deviceId,
    Logger? logger,
    ProcessManager? processManager,
  })  : _logger = logger ?? Logger(),
        _driver = File(join(projectDirectory.path, '.fluttium_driver.dart')),
        _processManager = processManager ?? const LocalProcessManager();

  /// The flow file to run.
  final File flowFile;

  /// The parsed flow file.
  FluttiumFlow? flow;

  /// The project directory to run in.
  final Directory projectDirectory;

  /// The device id to run on.
  final String deviceId;

  final Logger _logger;

  MasonGenerator? _generator;

  /// The result of each previous step that has been run.
  ///
  /// If it is `null` then we just started that step, otherwise it is the
  /// success status of the step that matches the index in the list.
  final List<bool?> _stepStates = [];

  final File _driver;

  final Map<String, dynamic> _vars = {};

  final ProcessManager _processManager;

  /// Execute the given [action].
  void _executeAction(String action, String? data) {
    switch (action) {
      case 'start':
        _stepStates.add(null);
        break;
      case 'fail':
        _stepStates.last = false;
        break;
      case 'done':
        _stepStates.last = true;
        break;
      case 'screenshot':
        final step = flow!.steps[_stepStates.length - 1];
        final bytes = data!.split(',').map(int.parse).toList();
        File(join(projectDirectory.path, 'screenshots', '${step.text}.png'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);
        break;
      default:
        throw Exception('Unknown action: $action');
    }
  }

  void _convertFlowToVars() {
    _vars.addAll({
      'flowDescription': flow!.description,
      'flowSteps': flow!.steps
          .map((e) {
            switch (e.action) {
              case FluttiumAction.expectVisible:
                return "await tester.expectVisible(r'${e.text}');";
              case FluttiumAction.expectNotVisible:
                return "await tester.expectNotVisible(r'${e.text}');";
              case FluttiumAction.tapOn:
                return "await tester.tapOn(r'${e.text}');";
              case FluttiumAction.inputText:
                return "await tester.inputText(r'${e.text}');";
              case FluttiumAction.takeScreenshot:
                return "await tester.takeScreenshot(r'${e.text}');";
            }
          })
          .map((e) => {'step': e})
          .toList(),
    });
  }

  Future<void> _setupProject() async {
    Future<bool> installSDKDeps(
      List<String> dependencies,
      String dependency,
    ) async {
      if (dependencies.where((e) => e == dependency).isEmpty) {
        await _processManager.run(
          ['flutter', 'pub', 'add', dependency, '--sdk=flutter', '--dev'],
          runInShell: true,
          workingDirectory: Directory.current.path,
        );
        return true;
      }
      return false;
    }

    final installingDeps = _logger.progress('Installing dependencies');

    final dependencyData = await _processManager.run(
      ['flutter', 'pub', 'deps', '--json'],
      runInShell: true,
      workingDirectory: Directory.current.path,
    );

    final projectData = jsonDecode(dependencyData.stdout as String) as Map;
    final project = (projectData['packages'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['name'] == projectData['root']);

    _vars['projectName'] = projectData['root'];
    _vars['addedIntegrationTests'] = await installSDKDeps(
      (project['dependencies'] as List).cast<String>(),
      'integration_test',
    );
    _vars['addedFlutterTest'] = await installSDKDeps(
      (project['dependencies'] as List).cast<String>(),
      'flutter_test',
    );

    await _processManager.run(
      ['flutter', 'pub', 'get'],
      runInShell: true,
      workingDirectory: Directory.current.path,
    );

    installingDeps.complete();
  }

  Future<void> _generateDriver() async {
    // Read the flow file and parse it. This keeps it fresh in case it changed.
    flow = FluttiumFlow(flowFile.readAsStringSync());
    _convertFlowToVars();

    _generator ??= await MasonGenerator.fromBundle(fluttiumDriverBundle);
    await _generator!.generate(
      DirectoryGeneratorTarget(projectDirectory),
      vars: _vars,
    );
  }

  Future<void> _cleanupProject() async {
    if (_driver.existsSync()) {
      _driver.deleteSync();
    }

    if (_vars['addedIntegrationTests'] as bool? ?? false) {
      await _processManager.run(
        ['flutter', 'pub', 'remove', 'integration_test'],
        runInShell: true,
        workingDirectory: projectDirectory.path,
      );
    }

    if (_vars['addedFlutterTest'] as bool? ?? false) {
      await _processManager.run(
        ['flutter', 'pub', 'remove', 'flutter_test'],
        runInShell: true,
        workingDirectory: Directory.current.path,
      );
    }
    await _generator!.hooks.postGen(
      vars: _vars,
      workingDirectory: projectDirectory.path,
      onVarsChanged: _vars.addAll,
    );
  }

  void _renderFlowState() {
    // Reset the cursor to the top of the screen and clear the screen.
    _logger.info('''
\u001b[0;0H\u001b[0J
  ${styleBold.wrap(flow!.description)}
''');

    for (var i = 0; i < flow!.steps.length; i++) {
      final step = flow!.steps[i];

      final String actionDescription;
      switch (step.action) {
        case FluttiumAction.expectVisible:
          actionDescription = 'Expect visible "${step.text}"';
          break;
        case FluttiumAction.expectNotVisible:
          actionDescription = 'Expect not visible "${step.text}"';
          break;
        case FluttiumAction.tapOn:
          actionDescription = 'Tap on "${step.text}"';
          break;
        case FluttiumAction.inputText:
          actionDescription = 'Input text "${step.text}"';
          break;
        case FluttiumAction.takeScreenshot:
          actionDescription = 'Screenshot "${step.text}"';
          break;
      }

      if (i < _stepStates.length) {
        final state = _stepStates[i];
        if (state == null) {
          _logger.info('  ⏳  $actionDescription');
        } else if (state) {
          _logger.info('  ✅  $actionDescription');
        } else {
          _logger.info('  ❌  $actionDescription');
        }
      } else {
        _logger.info('  🔲  $actionDescription');
      }
    }
    _logger.info('');
  }

  /// Runs the flow.
  ///
  /// If [watch] is true, the flow will be re-run whenever the flow file
  /// changed or the application code changed.
  Future<void> run({bool watch = false}) async {
    await _setupProject();
    await _generateDriver();

    final startingUpTestDriver = _logger.progress('Starting up test driver');
    final process = await _processManager.start(
      ['flutter', 'run', '.fluttium_driver.dart', '-d', deviceId],
      runInShell: true,
      workingDirectory: projectDirectory.path,
    );

    var isCompleted = false;
    final buffer = StringBuffer();
    process.stdout.listen((event) async {
      final data = utf8.decode(event).trim();
      buffer.write(data);

      // Skip until we see the first line of the test output.
      if (!isCompleted &&
          data.startsWith(RegExp(r'^[I/]*flutter[\s*\(\s*\d+\)]*: '))) {
        startingUpTestDriver.complete();
        isCompleted = true;
      }

      // Skip until the driver is ready.
      if (!isCompleted) return;

      final regex = RegExp('fluttium:(start|fail|done|screenshot):(.*?);');
      final matches = regex.allMatches(buffer.toString());

      // If matches is not empty, clear the buffer and check if the last match
      // is the end of the buffer. If it is not, we add what is left back to
      // the buffer.
      if (matches.isNotEmpty) {
        final content = buffer.toString();
        final lastMatch = matches.last;

        buffer.clear();
        if (content.length > lastMatch.end) {
          buffer.write(content.substring(lastMatch.end));
        }
      }

      for (final match in matches) {
        _executeAction(match.group(1)!, match.group(2));
      }

      _renderFlowState();

      // If we have completed all the steps, or if we have failed, exit the
      // process unless we are in watch mode.
      if (!watch &&
          (_stepStates.length == flow!.steps.length ||
              _stepStates.any((e) => e == false))) {
        process.stdin.write('q');
      }
    });

    final stderrBuffer = StringBuffer();
    process.stderr.listen((event) {
      stderrBuffer.write(utf8.decode(event));
    });

    // If we are in watch mode, we need to watch the flow file and the
    // application code for changes.
    if (watch) {
      // If the application code changes, we clear the step states and
      // hot restart the application.
      final projectWatcher = DirectoryWatcher(projectDirectory.path);
      projectWatcher.events.listen((event) {
        if (event.path.endsWith('.dart')) {
          _stepStates.clear();
          process.stdin.write('R');
        }
      });

      // If the flow file changes, we clear the step states and re-generate
      // the driver before hot restarting the application.
      final flowWatcher = FileWatcher(flowFile.path);
      flowWatcher.events.listen((event) async {
        await _generateDriver();
        _stepStates.clear();
        process.stdin.write('R');
      });
    }

    // Watching if our process gets killed, and if it does, we clean up the
    // project and exit the flutter process.
    final onSigintSubscription = ProcessSignal.sigint.watch().listen(
      (signal) async {
        process.stdin.write('q');
        await _cleanupProject();
      },
    );

    // Wait for the process to exit, and then clean up the project.
    await process.exitCode;
    await onSigintSubscription.cancel();
    await _cleanupProject();

    if (stderrBuffer.isNotEmpty) {
      _logger.err(stderrBuffer.toString());
    }
  }
}