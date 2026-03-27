param([switch]$SkipBuild, [switch]$DryRun)

Write-Host "`n=== Auto-Deploy cu Cache Busting ===" -ForegroundColor Cyan

# 1. Citeste versiunea
Write-Host "[1/5] Citesc pubspec.yaml..."
$pubspec = Get-Content "pubspec.yaml" -Raw
if ($pubspec -match 'version:\s+([\d.]+)\+(\d+)') {
    $version = $matches[1]
    $build = [int]$matches[2]
} else {
    Write-Host "ERROR: version not found!" -ForegroundColor Red
    exit 1
}

$newBuild = $build + 1
Write-Host "  Versiune: $version+$build -> $version+$newBuild"

# 2. Updateaza pubspec.yaml
if (-not $DryRun) {
    Write-Host "[2/5] Update pubspec.yaml..."
    $newPubspec = $pubspec -replace "version:\s+$([regex]::Escape($version))\+$build", "version: $version+$newBuild"
    Set-Content "pubspec.yaml" $newPubspec -NoNewline
    Write-Host "  OK"
} else {
    Write-Host "[2/5] [DRY] Update pubspec.yaml"
}

# 3. Updateaza web/index.html
if (-not $DryRun) {
    Write-Host "[3/5] Update web/index.html..."
    $html = Get-Content "web/index.html" -Raw
    $html = $html -replace "const CACHE_VERSION = '[^']*'", "const CACHE_VERSION = 'sw-cache-reset-v$version'"
    Set-Content "web/index.html" $html -NoNewline
    Write-Host "  OK"
} else {
    Write-Host "[3/5] [DRY] Update web/index.html"
}

# 4-5. Build si deploy
if ($SkipBuild) {
    Write-Host "[4/5] Sarit peste build"
    Write-Host "[5/5] Versiuni actualizate - ruleaza build manual"
} else {
    if (-not $DryRun) {
        Write-Host "[4/5] Build Flutter..."
        flutter clean
        flutter build web --release
        Write-Host "  OK"
    } else {
        Write-Host "[4/5] [DRY] Build Flutter"
    }
    
    if (-not $DryRun) {
        Write-Host "[5/5] Deploy Firebase..."
        firebase deploy --only hosting
        Write-Host "  OK - LIVE!" -ForegroundColor Green
    } else {
        Write-Host "[5/5] [DRY] Deploy Firebase"
    }
}

Write-Host "`n=== DONE ===" -ForegroundColor Cyan
