# ==============================================================================
# Script: HighResBraille_Dithered_Robust.ps1
# Target: PowerShell 7.6 (Windows 11)
# Function: High-resolution Image -> Braille with Floyd-Steinberg Dithering
# ==============================================================================

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# --- ADJUST FOR RESOLUTION ---
$TargetWidth = 30   
$BrightnessAdj = 1.1 
# -----------------------------

$FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{ 
    InitialDirectory = [Environment]::GetFolderPath('MyPictures')
    Filter = 'Image Files (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp'
    Title = 'Select Image for LLM Vision Experiment'
}

if ($FileBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    try {
        $Source = [System.Drawing.Bitmap]::FromFile($FileBrowser.FileName)
        
        $NewWidth = $TargetWidth * 2
        $NewHeight = [int]($Source.Height * ($NewWidth / $Source.Width))
        $NewHeight = $NewHeight - ($NewHeight % 4)

        $Canvas = New-Object System.Drawing.Bitmap($NewWidth, $NewHeight)
        $G = [System.Drawing.Graphics]::FromImage($Canvas)
        $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $G.DrawImage($Source, 0, 0, $NewWidth, $NewHeight)

        # Use a flattened 1D array to avoid [System.Object[]] method invocation errors
        $PixelCount = $NewWidth * $NewHeight
        $Pixels = [double[]]::new($PixelCount)

        for ($y=0; $y -lt $NewHeight; $y++) {
            for ($x=0; $x -lt $NewWidth; $x++) {
                $p = $Canvas.GetPixel($x, $y)
                $lum = ($p.R * 0.2126 + $p.G * 0.7152 + $p.B * 0.0722) / 255
                $Pixels[$y * $NewWidth + $x] = [Math]::Min(1.0, $lum * $BrightnessAdj)
            }
        }

        # Floyd-Steinberg Dithering (Standard Error Diffusion)
        # 
        for ($y=0; $y -lt $NewHeight; $y++) {
            for ($x=0; $x -lt $NewWidth; $x++) {
                $idx = $y * $NewWidth + $x
                $oldPixel = $Pixels[$idx]
                $newPixel = if ($oldPixel -gt 0.5) { 1.0 } else { 0.0 }
                $Pixels[$idx] = $newPixel
                $diff = $oldPixel - $newPixel

                # Helper to distribute error safely
                if ($x + 1 -lt $NewWidth) { $Pixels[$idx + 1] += $diff * 7/16 }
                if ($y + 1 -lt $NewHeight) {
                    if ($x - 1 -ge 0) { $Pixels[($y + 1) * $NewWidth + ($x - 1)] += $diff * 3/16 }
                    $Pixels[($y + 1) * $NewWidth + $x] += $diff * 5/16
                    if ($x + 1 -lt $NewWidth) { $Pixels[($y + 1) * $NewWidth + ($x + 1)] += $diff * 1/16 }
                }
            }
        }

        # Map to Braille Unicode (U+2800)
        # 
        $Output = New-Object System.Text.StringBuilder
        for ($y=0; $y -lt $NewHeight; $y+=4) {
            for ($x=0; $x -lt $NewWidth; $x+=2) {
                $byte = 0
                # Check bits in 2x4 pattern
                if ($Pixels[($y+0)*$NewWidth + $x+0] -gt 0.5) { $byte += 0x01 }
                if ($Pixels[($y+1)*$NewWidth + $x+0] -gt 0.5) { $byte += 0x02 }
                if ($Pixels[($y+2)*$NewWidth + $x+0] -gt 0.5) { $byte += 0x04 }
                if ($Pixels[($y+0)*$NewWidth + $x+1] -gt 0.5) { $byte += 0x08 }
                if ($Pixels[($y+1)*$NewWidth + $x+1] -gt 0.5) { $byte += 0x10 }
                if ($Pixels[($y+2)*$NewWidth + $x+1] -gt 0.5) { $byte += 0x20 }
                if ($Pixels[($y+3)*$NewWidth + $x+0] -gt 0.5) { $byte += 0x40 }
                if ($Pixels[($y+3)*$NewWidth + $x+1] -gt 0.5) { $byte += 0x80 }
                
                [void]$Output.Append([char](0x2800 + $byte))
            }
            [void]$Output.Append("`r`n")
        }

        $FinalResult = $Output.ToString()
        Write-Host $FinalResult
        $FinalResult | Set-Clipboard
        
        Write-Host "--- SUCCESS ---" -ForegroundColor Green
        Write-Host "Dithered high-res representation is in your clipboard."
        
        $Source.Dispose(); $Canvas.Dispose(); $G.Dispose()
    } 
    catch { 
        Write-Error "Processing Error: $($_.Exception.Message)" 
    }
}
else {
    Write-Host "No file selected." -ForegroundColor Yellow
}