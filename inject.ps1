$lines = Get-Content "d:\scr-miniaz\Set2up.ps1"
$new = $lines[0..102] + (Get-Content "d:\scr-miniaz\replacement.txt") + $lines[340..($lines.Count-1)]
Set-Content "d:\scr-miniaz\Set2up.ps1" -Value $new -Encoding UTF8
