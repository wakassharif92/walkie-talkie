import 'dart:io';

Future<void> registerAppProtocol(String scheme) async {
  if (!Platform.isWindows) return;

  final appPath = Platform.resolvedExecutable;
  final escapedCommand = '"$appPath" "%1"'.replaceAll("'", "''");
  final script = '''
\$base = "HKCU:\\Software\\Classes\\$scheme"
New-Item -Path \$base -Force | Out-Null
New-ItemProperty -Path \$base -Name "URL Protocol" -Value "" -PropertyType String -Force | Out-Null
New-Item -Path "\$base\\shell\\open\\command" -Force | Out-Null
Set-Item -Path "\$base\\shell\\open\\command" -Value '$escapedCommand'
''';

  final result = await Process.run(
    'powershell',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      'powershell',
      const ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command'],
      result.stderr.toString(),
      result.exitCode,
    );
  }
}
