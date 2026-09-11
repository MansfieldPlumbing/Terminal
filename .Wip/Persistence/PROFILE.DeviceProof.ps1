$view = [Android.Widget.TextView]::new($Activity)
$view.Text = "PROFILE_OK`nPSScriptRoot=$PSScriptRoot"
$view.TextSize = 36
$view.SetTextColor([Android.Graphics.Color]::White)
$view.SetBackgroundColor([Android.Graphics.Color]::Rgb(11, 61, 46))
$Activity.SetContentView($view)
