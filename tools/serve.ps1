<#
  serve.ps1 — a tiny static file server for DEV PREVIEW of the shell (src/shell).
  On device the C# ObpHost serves these from RAM; this is the browser-preview stand-in.
  Serves with correct MIME (ES modules need a real JS type; .obp is text/html).
  Binds localhost only (no urlacl/admin needed). Not for production.
#>
param(
  [string]$Root = 'S:\terminal-project\src\shell',
  [int]$Port = 7780
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path $Root).Path
$mime = @{
  '.html'='text/html; charset=utf-8'; '.obp'='text/html; charset=utf-8'
  '.js'='application/javascript; charset=utf-8'; '.mjs'='application/javascript; charset=utf-8'
  '.css'='text/css; charset=utf-8'; '.json'='application/json; charset=utf-8'
  '.svg'='image/svg+xml'; '.ttf'='font/ttf'; '.woff'='font/woff'; '.woff2'='font/woff2'
  '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.ico'='image/x-icon'
  '.map'='application/json'; '.wasm'='application/wasm'
}
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "serve.ps1: http://localhost:$Port/  root=$Root"
while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    $req = $ctx.Request; $res = $ctx.Response
    $rel = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
    if ([string]::IsNullOrEmpty($rel)) { $rel = 'index.html' }
    $full = Join-Path $Root $rel
    Write-Host ("{0} {1}" -f $req.HttpMethod, $req.Url.AbsolutePath)
    if (Test-Path $full -PathType Leaf) {
      $ext = [System.IO.Path]::GetExtension($full).ToLower()
      $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
      $res.Headers['Cache-Control'] = 'no-store'
      $bytes = [System.IO.File]::ReadAllBytes($full)
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      # The shell's API endpoints (/apps /themes /theme /verbs /shell-layout) have no static file;
      # answer with empty JSON so Registry.js/themes.js degrade cleanly instead of logging 404 noise.
      if ($rel -in 'apps','verbs','shell-layout','themes' ) { $res.ContentType='application/json'; $b=[Text.Encoding]::UTF8.GetBytes('[]'); $res.OutputStream.Write($b,0,$b.Length) }
      elseif ($rel -eq 'theme') { $res.ContentType='application/json'; $b=[Text.Encoding]::UTF8.GetBytes('{}'); $res.OutputStream.Write($b,0,$b.Length) }
      else { $res.StatusCode = 404 }
    }
    $res.OutputStream.Close()
  } catch { Write-Host "ERR: $($_.Exception.Message)" }
}
