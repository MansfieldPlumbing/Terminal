Write-Host "Building React Frontend..." -ForegroundColor Cyan
Set-Location Frontend
npm install
npm run build
Set-Location ..

Write-Host "Syncing Assets to Android Backend..." -ForegroundColor Cyan
if (Test-Path "Backend\Assets\wwwroot") { Remove-Item -Recurse -Force "Backend\Assets\wwwroot" }
New-Item -ItemType Directory -Force "Backend\Assets\wwwroot" | Out-Null
Copy-Item -Path "Frontend\dist\*" -Destination "Backend\Assets\wwwroot\" -Recurse -Force

Write-Host "Compiling and Pushing to Device via ADB..." -ForegroundColor Green
Set-Location Backend
dotnet build -c Release -t:Run -f net11.0-android
Set-Location ..


