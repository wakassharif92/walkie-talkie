import 'dart:io';

Future<void> registerAppProtocol(String scheme) async {
  if (!Platform.isWindows) return;

  final appPath = Platform.resolvedExecutable;
  final command = '"$appPath" "%1"';
  final script = '''
\$base = "HKCU:\\Software\\Classes\\$scheme"
New-Item -Path \$base -Force | Out-Null
New-ItemProperty -Path \$base -Name "URL Protocol" -Value "" -PropertyType String -Force | Out-Null
New-Item -Path "\$base\\shell\\open\\command" -Force | Out-Null
Set-ItemProperty -Path "\$base\\shell\\open\\command" -Name "(default)" -Value '$command'
''';

  await Process.run(
    'powershell',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
  );
}
