# audio_service 0.18.19, patched for Minstrel

A copy of [audio_service](https://pub.dev/packages/audio_service) 0.18.19
(lib, android, darwin) with two Android fixes, marked `// Minstrel` in the
code. The app picks it up through `dependency_overrides` in its pubspec.

- `AudioService.onCreate` hands the media session's commands to the running
  engine again (`AudioServicePlugin.reattachHandler`). Upstream connects them
  only when an engine attaches, so once Android had destroyed and recreated
  the playback service, Play and Pause from the car, the lock screen or
  headphones were silently dropped until the app was restarted.
- `AudioServicePlugin.disposeFlutterEngine` no longer destroys the engine.
  The app starts it in `MinstrelApplication` with its own channels; a new
  engine created after destroying it lacked them and hung at the splash
  screen.

To move to a newer audio_service, copy its lib, android and darwin folders
here and apply both changes again, or drop the copy if upstream has fixed
them.
