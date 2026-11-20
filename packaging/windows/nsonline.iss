; NSOnline installer (Inno Setup 6.3+).
;
; Build (from the repo root, after `flutter build windows --release` and the
; backend copied as nsonline-core.exe next to nsonline.exe):
;   iscc /DAppVersion=0.1.0 packaging\windows\nsonline.iss
; Optional: /DBuildDir=<Flutter Release folder>  /O<output dir>
;
; Per-user install (no admin rights), so the in-app updater can run
;   NSOnline-<ver>-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /NORESTART
; and the [Run] section relaunches the app afterwards.

#ifndef AppVersion
  #error Pass the version: iscc /DAppVersion=x.y.z nsonline.iss
#endif
#ifndef BuildDir
  #define BuildDir AddBackslash(SourcePath) + "..\..\app\build\windows\x64\runner\Release"
#endif
#define AppName "NSOnline"
#define AppExe "nsonline.exe"
#define BackendExe "nsonline-core.exe"
#define AppPublisher "dorydev"
#define AppURL "https://github.com/dorydev/NSOnline"

#if !FileExists(AddBackslash(BuildDir) + AppExe)
  #error nsonline.exe not found in BuildDir: run flutter build windows --release first
#endif
#if !FileExists(AddBackslash(BuildDir) + BackendExe)
  #error nsonline-core.exe not found in BuildDir: copy the backend next to nsonline.exe first
#endif

[Setup]
; Fixed forever: identifies the installation for upgrades and uninstall.
AppId={{0E858324-1539-4B3B-8271-A5C6D199FD57}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
AppCopyright=Copyright (C) 2026 dorydev - AGPL-3.0-or-later
VersionInfoVersion={#AppVersion}
LicenseFile=..\..\LICENSE

; Per-user by default (installs to %LOCALAPPDATA%\Programs\NSOnline).
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
UsePreviousAppDir=yes
UsePreviousTasks=yes

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

; Close the running app (and its backend) through the Restart Manager; we
; relaunch it ourselves in [Run] rather than letting Restart Manager do it.
CloseApplications=yes
CloseApplicationsFilter=*.exe
RestartApplications=no

OutputDir=..\..\dist
OutputBaseFilename=NSOnline-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
french.StartupTask=Lancer NSOnline au démarrage de Windows
english.StartupTask=Start NSOnline when Windows starts
french.StartupGroup=Démarrage :
english.StartupGroup=Startup:

[Tasks]
Name: "startup"; Description: "{cm:StartupTask}"; GroupDescription: "{cm:StartupGroup}"; Flags: unchecked
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Flutter Release folder: nsonline.exe, flutter_windows.dll, plugin
; DLLs, data\ (flutter_assets, icudtl.dat, app.so) and nsonline-core.exe.
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{autostartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: startup

[Run]
; Interactive install: "Launch NSOnline" checkbox on the last page.
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
; Silent install (in-app updater): relaunch unconditionally.
Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Flags: nowait runasoriginaluser; Check: WizardSilent

[UninstallRun]
; Make sure neither process keeps files locked during uninstall.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExe}"; Flags: runhidden; RunOnceId: "KillApp"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#BackendExe}"; Flags: runhidden; RunOnceId: "KillBackend"
