Write-Host "Building React Frontend..." -ForegroundColor Cyan
Set-Location ReactUI
npm install
npm run build
Set-Location ..

Write-Host "Syncing Assets..." -ForegroundColor Cyan
if (Test-Path "Assets\wwwroot") { Remove-Item -Recurse -Force "Assets\wwwroot" }
New-Item -ItemType Directory -Force "Assets\wwwroot" | Out-Null
Copy-Item -Path "ReactUI\dist\*" -Destination "Assets\wwwroot\" -Recurse -Force

Write-Host "Compiling and Pushing to Device via ADB..." -ForegroundColor Green
dotnet build -c Release -t:Run -f net11.0-android

