param(
  [string]$ProjectRoot = (Join-Path $env:USERPROFILE "Desktop\hwadam-mini-pc-one-click-package")
)

$ErrorActionPreference = "Stop"
$PackageUrl = "https://raw.githubusercontent.com/ycx1678/hwadam-one-time-update-736c645/main/hwadam-source-261ad0f.zip"
$TemporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "hwadam-one-time-update-$([guid]::NewGuid().ToString('N'))"
$ArchivePath = Join-Path $TemporaryRoot "hwadam-source.zip"
$SourceRoot = Join-Path $TemporaryRoot "source"

if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "package.json"))) {
  throw "사이트 폴더를 찾지 못했습니다: $ProjectRoot"
}

try {
  New-Item -ItemType Directory -Path $SourceRoot -Force | Out-Null
  Write-Host "1/5 최신 사이트 파일을 받습니다."
  Invoke-WebRequest -UseBasicParsing -Uri $PackageUrl -OutFile $ArchivePath
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $SourceRoot -Force
  if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot "package.json"))) {
    throw "받은 업데이트 파일 구성이 올바르지 않습니다."
  }

  Write-Host "2/5 최신 소스를 적용합니다."
  $directories = @(".openai", "app", "build", "components", "db", "drizzle", "examples", "lib", "public", "selfhost", "tests", "worker")
  foreach ($directory in $directories) {
    $sourceDirectory = Join-Path $SourceRoot $directory
    if (-not (Test-Path -LiteralPath $sourceDirectory)) { continue }
    $destinationDirectory = Join-Path $ProjectRoot $directory
    & robocopy.exe $sourceDirectory $destinationDirectory /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "$directory 파일 적용에 실패했습니다. (robocopy: $LASTEXITCODE)" }
  }

  $files = @(".gitignore", "drizzle.config.ts", "eslint.config.mjs", "next-env.d.ts", "next.config.ts", "package-lock.json", "package.json", "postcss.config.mjs", "README.md", "tsconfig.json", "vite.config.ts")
  foreach ($file in $files) {
    $sourceFile = Join-Path $SourceRoot $file
    if (Test-Path -LiteralPath $sourceFile) {
      Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $ProjectRoot $file) -Force
    }
  }

  Push-Location $ProjectRoot
  try {
    Write-Host "3/5 사이트를 빌드합니다."
    & npm.cmd run build
    if ($LASTEXITCODE -ne 0) { throw "사이트 빌드에 실패했습니다." }

    Write-Host "4/5 사이트와 배포 수신기를 최신 설정으로 시작합니다."
    & node.exe .\selfhost\ensure-pm2-site.cjs
    if ($LASTEXITCODE -ne 0) { throw "사이트 실행 설정 적용에 실패했습니다." }
    & pm2.cmd save
    if ($LASTEXITCODE -ne 0) { throw "PM2 설정 저장에 실패했습니다." }

    Write-Host "5/5 로컬 사이트 응답을 확인합니다."
    $healthy = $false
    foreach ($attempt in 1..15) {
      Start-Sleep -Seconds 1
      try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:3000" -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
          $healthy = $true
          break
        }
      } catch {
        # PM2가 사이트를 시작하는 동안 다음 시도에서 다시 확인합니다.
      }
    }
    if (-not $healthy) { throw "사이트가 3000번 포트에서 정상 응답하지 않습니다." }
  } finally {
    Pop-Location
  }

  Write-Host "완료: 최신 사이트가 미니PC에 적용되었습니다."
} finally {
  if (Test-Path -LiteralPath $TemporaryRoot) {
    Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
