# Device evidence — recording persistence audit

Parent read-only Android inspection of the current installed app found the exact save failure in PID-scoped Flutter logcat:

```
Unhandled Exception: InvalidDataException: ... DumpRow(... title: , ... audioPath: /storage/emulated/0/Documents/Tangent/1789341285253510.opus, audioSizeBytes: 19740 ...) cannot be used ...
• title: Must at least be 1 characters long.
#5 LocalDb.upsertDump (package:tangent/data/local_db.dart:81:19)
#6 _HomeScreenState._toggleRecording (package:tangent/screens/home/home_screen.dart:57:16)
```

`local_db.dart` defines `title => text().withLength(min: 1, max: 500)()`; recording stop inserts empty title. Startup orphan import also inserts empty title and catches all failures. This is concrete cause of saved audio not appearing in app, not a hypothetical storage/codec failure.

Parent copied existing public files (read-only on phone) to `~/Documents/ADH2-device-backups/recording-audit/Tangent/`. `ffprobe` returned exit 0 for all three copied files with Opus mono streams:

| File | Bytes | Reported duration (seconds) |
| --- | ---: | ---: |
| 1789341285253510.opus | 19740 | 3.660000 |
| 1789341298719612.opus | 48866 | 9.500000 |
| 1789341316480694.opus | 1319825 | 305.660000 |

The first snapshot of the last file was taken during recording. After Jeff authorized continuing through rebuild/reinstall, the parent inspected the live screen (timer 08:32), tapped the visible stop control, and copied all files again. The finalized last file is 2462736 bytes with ffprobe duration 535.420000 seconds. All THREE finalized backed-up files were fully decoded using `ffmpeg -nostdin -v error -xerror -i <file> -f null -`, each exiting 0 with no errors. Stop reproduced the same title-validation exception at 19:24:12 in Flutter logcat. No files were removed and the app was not force-stopped or uninstalled.

`adb shell appops get dev.tangent.tangent MANAGE_EXTERNAL_STORAGE` reported `default` with a recent rejection, although the current recordings did reach public Documents. Do not equate a missing all-files grant with proof no files could be created. Verify each operation; existing app-created files and reinstall access differ.

Permission flow still needs audit: current `StoragePermission.documentsDir()` silently falls back to systemTemp on exception; `requestManageAllFiles` is declared but the previous implementation did not wire it into UI. Metadata sidecars were declared but not actually persisted. These remain separate architectural defects.

Current device was connected and app process running at inspection. Do not uninstall/clear data to reproduce. Parent owns phone interactions; code worker owns implementation/testing/build.
