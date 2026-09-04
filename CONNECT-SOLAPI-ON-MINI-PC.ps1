param(
  [string]$ProjectRoot = (Join-Path $env:USERPROFILE "Desktop\hwadam-mini-pc-one-click-package")
)

$ErrorActionPreference = "Stop"

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

$environmentPath = Join-Path $ProjectRoot "selfhost\.env"
if (-not (Test-Path -LiteralPath $environmentPath)) {
  throw "미니PC의 selfhost\.env 파일을 찾지 못했습니다: $environmentPath"
}

Write-Host "솔라피 API Key를 연결합니다."
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
  Write-Host "사이트를 다시 시작합니다."
  & node.exe .\selfhost\ensure-pm2-site.cjs
  if ($LASTEXITCODE -ne 0) { throw "사이트 실행 설정 적용에 실패했습니다." }
  & pm2.cmd save
  if ($LASTEXITCODE -ne 0) { throw "PM2 설정 저장에 실패했습니다." }

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
      # 사이트가 시작되는 동안 다음 시도에서 다시 확인합니다.
    }
  }
  if (-not $healthy) { throw "사이트가 3000번 포트에서 정상 응답하지 않습니다." }
} finally {
  Pop-Location
}

Write-Host "완료: 솔라피 알림톡 연결값을 저장하고 사이트를 다시 시작했습니다."
Write-Host "이 파일은 사이트 코드와 기존 data 폴더를 변경하지 않습니다."
