; SPDX-License-Identifier: AGPL-3.0-or-later
; Tangent Windows installer.
;
; Per-user install (no admin prompt): PrivilegesRequired=lowest puts the
; app under %LOCALAPPDATA%\Programs\Tangent, matching how VS Code and
; Discord ship. The build script passes /DAppVersion=<version from
; pubspec.yaml> so the installer version can never drift from the app's.
;
; Close-to-tray interacts with upgrades: the running instance holds the
; exe locked while hidden in the tray, so the installer asks Windows to
; close it (CloseApplications) rather than failing the file copy.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BundleDir
  #define BundleDir "..\client\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{7E1B3C63-52D4-4A44-9C7B-5A05B5F41B7A}
AppName=Tangent
AppVersion={#AppVersion}
AppPublisher=Tangent
AppPublisherURL=https://github.com/GyratingSeaCow/tangent
DefaultDirName={userpf}\Tangent
DefaultGroupName=Tangent
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=tangent-setup-x64
OutputDir=out
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\tangent.exe
; The app holds its exe open while minimized to tray; ask it to close
; instead of dying on a locked file.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "Start Tangent when you sign in"; \
  GroupDescription: "Startup:"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Tangent"; Filename: "{app}\tangent.exe"
Name: "{userdesktop}\Tangent"; Filename: "{app}\tangent.exe"; \
  Tasks: desktopicon
; Startup shortcut rather than a registry Run key: visible in
; shell:startup, trivially removable, uninstalled with the app.
Name: "{userstartup}\Tangent"; Filename: "{app}\tangent.exe"; \
  Tasks: startup

[Run]
Filename: "{app}\tangent.exe"; Description: "{cm:LaunchProgram,Tangent}"; \
  Flags: nowait postinstall skipifsilent
