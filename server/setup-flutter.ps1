# Add Flutter SDK to PATH (session + persistent)
$env:Path = "$env:Path;~\AppData\Local\flutter\bin"
setx PATH "$env:PATH" 2>$null | Out-Null

# Verify
& "$env:LOCALAPPDATA\flutter\bin\flutter.bat" --version 2>&1 | Select-Object -First 5
Write-Host "---DOCTOR---"
& "$env:LOCALAPPDATA\flutter\bin\flutter.bat" doctor 2>&1 | Out-String