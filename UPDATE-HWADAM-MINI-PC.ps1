param(
  [string]$ProjectRoot = (Join-Path $env:USERPROFILE "Desktop\hwadam-mini-pc-one-click-package")
)

$ErrorActionPreference = "Stop"
$PackageUrl = "https://raw.githubusercontent.com/ycx1678/hwadam-one-time-update-736c645/main/hwadam-source-24f5d65.zip"
$TemporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "hwadam-one-time-update-$([guid]::NewGuid().ToString('N'))"
$ArchivePath = Join-Path $TemporaryRoot "hwadam-source.zip"
$SourceRoot = Join-Path $TemporaryRoot "source"

function Set-EnvironmentValue {
  param(
    [System.Collections.Generic.List[string]]$Lines,
    [string]$Name,
    [string]$Value
  )

  $prefix = "$Name="
  for ($index = 0; $index -lt $Lines.Count; $index += 1) {
    if ($Lines[$index].StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $Lines[$index] = "$Name=$Value"
      return
    }
  }
  $Lines.Add("$Name=$Value")
}

function Convert-SecureStringToPlainText {
  param([securestring]$Value)
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

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

  $environmentPath = Join-Path $ProjectRoot "selfhost\.env"
  if (-not (Test-Path -LiteralPath $environmentPath)) {
    throw "미니PC의 selfhost\.env 파일을 찾지 못했습니다: $environmentPath"
  }

  Write-Host "3/6 솔라피 API Key를 연결합니다."
  $solapiKey = (Read-Host "솔라피 API Key를 붙여넣으세요").Trim()
  $solapiSecret = Convert-SecureStringToPlainText (Read-Host "솔라피 API Secret을 붙여넣으세요" -AsSecureString)
  if (-not $solapiKey -or -not $solapiSecret) {
    throw "솔라피 API Key와 API Secret을 모두 입력해야 합니다."
  }

  $environmentLines = [System.Collections.Generic.List[string]]::new([string[]](Get-Content -LiteralPath $environmentPath))
  $solapiValues = [ordered]@{
    SOLAPI_API_KEY = $solapiKey
    SOLAPI_API_SECRET = $solapiSecret
    SOLAPI_SENDER = "01062161894"
    SOLAPI_KAKAO_CHANNEL_ID = "KA01PF260822081626836WY1pU0eZKMx"
    SOLAPI_CUSTOMER_TEMPLATE_ID = "KA01TP260823230624994UertNP9Ywig"
    SOLAPI_ADMIN_TEMPLATE_ID = "KA01TP260823230727058gKmhuTtIO6L"
    SOLAPI_ADMIN_PHONE = "01062161894"
  }
  foreach ($entry in $solapiValues.GetEnumerator()) {
    Set-EnvironmentValue -Lines $environmentLines -Name $entry.Key -Value $entry.Value
  }
  [System.IO.File]::WriteAllLines($environmentPath, $environmentLines, [System.Text.UTF8Encoding]::new($false))

  Push-Location $ProjectRoot
  try {
    Write-Host "4/6 사이트를 빌드합니다."
    & npm.cmd run build
    if ($LASTEXITCODE -ne 0) { throw "사이트 빌드에 실패했습니다." }

    Write-Host "5/6 사이트와 배포 수신기를 최신 설정으로 시작합니다."
    & node.exe .\selfhost\ensure-pm2-site.cjs
    if ($LASTEXITCODE -ne 0) { throw "사이트 실행 설정 적용에 실패했습니다." }
    & pm2.cmd save
    if ($LASTEXITCODE -ne 0) { throw "PM2 설정 저장에 실패했습니다." }

    Write-Host "6/6 로컬 사이트 응답을 확인합니다."
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

  Write-Host "완료: 최신 사이트와 솔라피 알림톡이 미니PC에 적용되었습니다."
} finally {
  if (Test-Path -LiteralPath $TemporaryRoot) {
    Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
