// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sqlite3 hook compiles the pinned vendored 3.50.2 amalgamation', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final File source = File('third_party/sqlite/sqlite3.c');
    final String sqlite = source.readAsStringSync();

    expect(
      RegExp(
        r'source: source\r?\n\s+path: third_party/sqlite/sqlite3\.c',
      ).hasMatch(pubspec),
      isTrue,
    );
    expect(pubspec, isNot(contains('sqlite3_flutter_libs:')));
    expect(sqlite, contains('#define SQLITE_VERSION        "3.50.2"'));
    expect(sqlite, contains('#define SQLITE_VERSION_NUMBER 3050002'));
    expect(
      sha256.convert(source.readAsBytesSync()).toString(),
      'c9a0b6829b81d5f1b78392181f09744c818117a725667411d517b98149fcd3be',
    );
  });

  test('Android PDF path is framework-only and PDFium hook skips Android', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final String lockfile = File('pubspec.lock').readAsStringSync();
    final String hook = File(
      'third_party/pdfium_dart/hook/build.dart',
    ).readAsStringSync();
    final String backend = File(
      'android/app/src/main/kotlin/dev/tangent/tangent/pdf/'
      'AndroidPdfRendererBackend.kt',
    ).readAsStringSync();
    final String activity = File(
      'android/app/src/main/kotlin/dev/tangent/tangent/MainActivity.kt',
    ).readAsStringSync();

    expect(RegExp(r'^\s+pdfrx:', multiLine: true).hasMatch(pubspec), isFalse);
    expect(pubspec, contains('pdfrx_engine: 0.6.1'));
    expect(pubspec, contains('path: third_party/pdfium_dart'));
    expect(RegExp(r'^  pdfrx:', multiLine: true).hasMatch(lockfile), isFalse);
    expect(
      RegExp(r'^  pdfium_flutter:', multiLine: true).hasMatch(lockfile),
      isFalse,
    );
    final int androidGuard = hook.indexOf(
      'input.config.code.targetOS == OS.android',
    );
    final int download = hook.indexOf('await _downloadPdfium(');
    expect(androidGuard, greaterThan(0));
    expect(androidGuard, lessThan(download));
    expect(backend, contains('android.graphics.pdf.PdfRenderer'));
    expect(backend, contains(r'PDF $purpose must be inside the app cache'));
    expect(activity, contains('dev.tangent.tangent/pdf_renderer'));
    expect(activity, contains('PdfRendererMethodRouter'));
  });

  test('release workflow builds each ABI in an isolated invocation', () {
    final String workflow = File(
      '../.github/workflows/release.yml',
    ).readAsStringSync();
    const List<String> expected = <String>[
      'flutter build apk --release --split-per-abi --target-platform android-arm',
      'flutter build apk --release --split-per-abi --target-platform android-arm64',
      'flutter build apk --release --split-per-abi --target-platform android-x64',
    ];

    for (final String command in expected) {
      expect(
        RegExp(
          '^\\s*${RegExp.escape(command)}\\s*\$',
          multiLine: true,
        ).allMatches(workflow).length,
        1,
        reason: command,
      );
    }
    expect(
      RegExp(
        r'^\s*flutter build apk --release --split-per-abi\s*$',
        multiLine: true,
      ).hasMatch(workflow),
      isFalse,
    );
    expect(
      workflow,
      contains(
        'for apk in app-release app-armeabi-v7a-release '
        'app-arm64-v8a-release app-x86_64-release; do',
      ),
    );
    expect(workflow, contains('grep -q "CN=Tangent"'));
    expect(
      File('android/app/build.gradle').readAsStringSync(),
      contains(
        'signingConfig = keystorePropertiesFile.exists() ? '
        'signingConfigs.release : signingConfigs.debug',
      ),
    );
  });

  test('release workflow pins native-assets NDK and blocks on audit failure', () {
    final String workflow = File(
      '../.github/workflows/release.yml',
    ).readAsStringSync();
    final int installStart = workflow.indexOf(
      '      - name: Install pinned Android NDK',
    );
    final int buildStart = workflow.indexOf(
      '      - name: Build release APKs (universal + per-ABI)',
    );
    final int auditStart = workflow.indexOf(
      '      - name: Audit release APKs',
    );
    final int auditEnd = workflow.indexOf(
      '      - name: Verify release signatures',
      auditStart,
    );

    expect(installStart, greaterThan(0));
    expect(buildStart, greaterThan(installStart));
    expect(auditStart, greaterThan(buildStart));
    expect(auditEnd, greaterThan(auditStart));

    final String installStep = workflow.substring(installStart, buildStart);
    expect(installStep, contains('ndk_version=28.2.13676358'));
    expect(
      installStep,
      contains(
          '"\$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "ndk;\$ndk_version"'),
    );
    expect(installStep, contains('for tool in clang llvm-ar ld.lld; do'));
    expect(installStep, contains('test -x "\$toolchain/\$tool"'));
    expect(
      installStep,
      contains(
        'for variable in ANDROID_NDK_HOME ANDROID_NDK_PATH '
        'ANDROID_NDK_ROOT; do',
      ),
    );
    expect(
      installStep,
      contains('echo "\$variable=\$ndk" >> "\$GITHUB_ENV"'),
    );

    final String auditStep = workflow.substring(auditStart, auditEnd);
    expect(
      RegExp(r'^        shell: bash\s*$', multiLine: true).hasMatch(auditStep),
      isTrue,
      reason: 'GitHub explicit bash supplies -eo pipefail for the audit pipeline',
    );
    expect(
      auditStep.indexOf('python tool/audit_android_release.py'),
      lessThan(auditStep.indexOf('| tee "\$RUNNER_TEMP/android-release-audit.json"')),
    );
  });
}
