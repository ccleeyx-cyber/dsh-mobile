# 从一张 1024×1024 的母版图生成 Android 启动图标（5 档密度）。
#
# 用法： pwsh -File scripts/make-app-icons.ps1
#        pwsh -File scripts/make-app-icons.ps1 -Source dsh_mobile/assets/branding/app-icon-1024.png
#
# 为什么不用 flutter_launcher_icons：本项目只换了图标这一件事，为它引一个构建期依赖
# 不划算；Android 需要的只是 5 个固定尺寸的 PNG，脚本 20 行就能生成。
#
# 母版约定：满幅正方形、四周留白（安全区），**不要把圆角烘进图里** —— 各家启动器
# 会自己裁形状，预烘圆角会露出一圈锯齿。
param(
  [string]$Source = 'dsh_mobile/assets/branding/app-icon-1024.png'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$srcPath = Join-Path $root $Source
if (-not (Test-Path $srcPath)) { throw "找不到母版图：$srcPath" }

# Android 各密度下 ic_launcher 的边长（1x=48dp）
$sizes = [ordered]@{
  'mdpi'    = 48
  'hdpi'    = 72
  'xhdpi'   = 96
  'xxhdpi'  = 144
  'xxxhdpi' = 192
}

$src = [System.Drawing.Image]::FromFile($srcPath)
if ($src.Width -ne $src.Height) { $src.Dispose(); throw "母版图必须是正方形，当前 $($src.Width)x$($src.Height)" }

try {
  foreach ($density in $sizes.Keys) {
    $side = $sizes[$density]
    $dir = Join-Path $root "dsh_mobile/android/app/src/main/res/mipmap-$density"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $out = Join-Path $dir 'ic_launcher.png'

    $bmp = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
      $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
      $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $side, $side)))
    } finally { $g.Dispose() }

    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $kb = [Math]::Round((Get-Item $out).Length / 1KB, 1)
    Write-Host ("  {0,-9} {1,3}x{1,-3} {2} KB" -f $density, $side, $kb)
  }
} finally { $src.Dispose() }

Write-Host "✓ 图标已更新（母版：$Source）"
