# ============================================================
# Datadog Secret Backend - Self-Contained Offline Setup
# Place this script in same folder as:
#   - datadog-secret-backend.exe
#   - datadog-secret-backend.yaml
# Run as Administrator
# ============================================================

# ============================================================
# *** CONFIGURE THESE BEFORE RUNNING ***
# ============================================================
$backendId  = "all_secrets"
$apiKeyName = "api_key"
# ============================================================

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = "C:\Program Files\datadog-secret-backend"
$exeSrc     = "$scriptDir\datadog-secret-backend.exe"
$yamlSrc    = "$scriptDir\datadog-secret-backend.yaml"
$exeDest    = "$backendDir\datadog-secret-backend.exe"
$yamlDest   = "$backendDir\datadog-secret-backend.yaml"
$ddConfig   = "C:\ProgramData\Datadog\datadog.yaml"
$encRef     = "ENC[" + $backendId + ":" + $apiKeyName + "]"
$secretCmd  = "C:\Program Files\datadog-secret-backend\datadog-secret-backend.exe"
$agentExe   = "C:\Program Files\Datadog\Datadog Agent\bin\agent.exe"


# ============================================================
Write-Host ""
Write-Host "=== Pre-flight Checks ===" -ForegroundColor Cyan

if (-not (Test-Path $exeSrc)) {
    Write-Host "ERROR: datadog-secret-backend.exe not found in $scriptDir" -ForegroundColor Red
    exit 1
}
Write-Host "EXE found: $exeSrc" -ForegroundColor Green

if (-not (Test-Path $yamlSrc)) {
    Write-Host "ERROR: datadog-secret-backend.yaml not found in $scriptDir" -ForegroundColor Red
    exit 1
}
Write-Host "YAML found: $yamlSrc" -ForegroundColor Green

if (-not (Test-Path $ddConfig)) {
    Write-Host "ERROR: Datadog Agent not installed. datadog.yaml not found." -ForegroundColor Red
    exit 1
}
Write-Host "Datadog Agent config found." -ForegroundColor Green

$yamlRaw = Get-Content $yamlSrc -Raw
if ($yamlRaw -match "YOUR_AWS_ACCESS_KEY_ID" -or $yamlRaw -match "YOUR_AWS_SECRET" -or $yamlRaw -match "REPLACE_WITH") {
    Write-Host "ERROR: datadog-secret-backend.yaml still contains placeholder values." -ForegroundColor Red
    Write-Host "       Fill in real aws_access_key_id, aws_secret_access_key, and secret_id first." -ForegroundColor Red
    exit 1
}
Write-Host "YAML credentials validated (no placeholders found)." -ForegroundColor Green
Write-Host "Using backend_id : $backendId" -ForegroundColor Cyan
Write-Host "Using api_key ref: $encRef" -ForegroundColor Cyan


# ============================================================
Write-Host ""
Write-Host "=== Step 1: Creating Backend Directory ===" -ForegroundColor Cyan
if (-not (Test-Path $backendDir)) {
    New-Item -ItemType Directory -Path $backendDir -Force | Out-Null
    Write-Host "Created: $backendDir" -ForegroundColor Green
} else {
    Write-Host "Already exists: $backendDir" -ForegroundColor Yellow
}


# ============================================================
Write-Host ""
Write-Host "=== Step 2: Copying Files ===" -ForegroundColor Cyan
Copy-Item -Path $exeSrc  -Destination $exeDest  -Force
Write-Host "Copied EXE  -> $exeDest" -ForegroundColor Green
Copy-Item -Path $yamlSrc -Destination $yamlDest -Force
Write-Host "Copied YAML -> $yamlDest" -ForegroundColor Green


# ============================================================
Write-Host ""
Write-Host "=== Step 3: Setting Permissions on EXE ===" -ForegroundColor Cyan
$acl = Get-Acl $exeDest
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM","FullControl","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("ddagentuser","ReadAndExecute","Allow")))
Set-Acl -Path $exeDest -AclObject $acl
Write-Host "EXE permissions set." -ForegroundColor Green


# ============================================================
Write-Host ""
Write-Host "=== Step 4: Setting Permissions on YAML ===" -ForegroundColor Cyan
$aclYaml = Get-Acl $yamlDest
$aclYaml.SetAccessRuleProtection($true, $false)
$aclYaml.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM","FullControl","Allow")))
$aclYaml.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")))
$aclYaml.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("ddagentuser","ReadAndExecute","Allow")))
Set-Acl -Path $yamlDest -AclObject $aclYaml
Write-Host "YAML permissions set." -ForegroundColor Green


# ============================================================
Write-Host ""
Write-Host "=== Step 5: Updating datadog.yaml ===" -ForegroundColor Cyan

# -------------------------------------------------------
# Strategy:
#   1. Remove ALL existing secret_backend_command lines
#   2. Remove ALL existing api_key lines (active + commented)
#   3. Inject api_key: ENC[] → after "## @param api_key" comment
#   4. Inject secret_backend_command → after "## @param secret_backend_type" comment
#      (its natural home in the Secrets section ~line 870)
# -------------------------------------------------------

$content = Get-Content $ddConfig

# Clean slate
$content = $content | Where-Object { $_ -notmatch "secret_backend_command" }
$content = $content | Where-Object { $_ -notmatch "^\s*#?\s*api_key:" }

$newContent    = [System.Collections.Generic.List[string]]::new()
$apiInjected   = $false
$secretInjected = $false

foreach ($line in $content) {
    $newContent.Add($line)

    # Inject api_key AFTER the "@param api_key - string - required" comment line
    if ((-not $apiInjected) -and ($line -match "@param api_key - string - required")) {
        $newContent.Add("api_key: $encRef")
        $apiInjected = $true
    }

    # Inject secret_backend_command AFTER the "@param secret_backend_type" comment line
    if ((-not $secretInjected) -and ($line -match "@param secret_backend_type")) {
        $newContent.Add("secret_backend_command: $secretCmd")
        $secretInjected = $true
    }
}

# Fallbacks
if (-not $apiInjected) {
    $newContent.Insert(0, "api_key: $encRef")
    Write-Host "WARNING: api_key anchor not found - prepended at top." -ForegroundColor Yellow
} else {
    Write-Host "api_key injected after @param api_key comment." -ForegroundColor Green
}

if (-not $secretInjected) {
    $newContent.Insert(0, "secret_backend_command: $secretCmd")
    Write-Host "WARNING: secret_backend_type anchor not found - prepended at top." -ForegroundColor Yellow
} else {
    Write-Host "secret_backend_command injected after @param secret_backend_type comment." -ForegroundColor Green
}

Set-Content $ddConfig $newContent -Encoding UTF8
Write-Host "datadog.yaml updated successfully." -ForegroundColor Green

# Confirm placement
Write-Host ""
Write-Host "Confirming injected lines:" -ForegroundColor Yellow
$allLines = Get-Content $ddConfig
for ($idx = 0; $idx -lt $allLines.Count; $idx++) {
    if ($allLines[$idx] -match "^api_key:|^secret_backend_command:") {
        $start = [Math]::Max(0, $idx - 1)
        $end   = [Math]::Min($allLines.Count - 1, $idx + 1)
        for ($j = $start; $j -le $end; $j++) {
            Write-Host ("  [{0,4}] {1}" -f ($j+1), $allLines[$j]) -ForegroundColor White
        }
        Write-Host "" 
    }
}


# ============================================================
Write-Host ""
Write-Host "=== Step 6: Restarting Datadog Agent ===" -ForegroundColor Cyan

$ddLines        = Get-Content $ddConfig
$cmdCount       = ($ddLines | Select-String -Pattern "^secret_backend_command:").Count
$apiKeyCount    = ($ddLines | Select-String -Pattern "^api_key:").Count

if ($cmdCount -ne 1) {
    Write-Host "ERROR: secret_backend_command appears $cmdCount times (expected 1)." -ForegroundColor Red
    exit 1
}
if ($apiKeyCount -ne 1) {
    Write-Host "ERROR: api_key appears $apiKeyCount times (expected 1)." -ForegroundColor Red
    exit 1
}
Write-Host "Duplicate key check passed (secret_backend_command x$cmdCount, api_key x$apiKeyCount)." -ForegroundColor Green

Stop-Service DatadogAgent -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Start-Service DatadogAgent -ErrorAction SilentlyContinue
Start-Sleep -Seconds 10

$svc = Get-Service DatadogAgent
if ($svc.Status -ne "Running") {
    Write-Host "WARNING: Agent not running after restart." -ForegroundColor Yellow
    Write-Host "  -> Fix credentials in $yamlDest then re-run setup.ps1" -ForegroundColor Yellow
} else {
    Write-Host "Agent restarted and running." -ForegroundColor Green
}


# ============================================================
Write-Host ""
Write-Host "=== Step 7: Testing Backend Directly ===" -ForegroundColor Cyan
$testInput  = "{`"version`": `"1.0`", `"secrets`": [`"" + $backendId + ":" + $apiKeyName + "`"]}"
Write-Host "Sending: $testInput" -ForegroundColor Yellow
$testResult = $testInput | & $exeDest 2>&1
Write-Host "Backend Response:" -ForegroundColor Yellow
Write-Output $testResult

$testJson = ($testResult | Where-Object { $_ -match "^\{" }) -join ""
if ($testJson -match '"error":null') {
    Write-Host "PASSED: Secret resolved successfully." -ForegroundColor Green
} elseif ($testJson -match "UnrecognizedClientException") {
    Write-Host "FAILED: AWS credentials are invalid." -ForegroundColor Red
    Write-Host "  -> Open $yamlDest" -ForegroundColor Yellow
    Write-Host "  -> Verify aws_access_key_id is 20 chars starting with AKIA" -ForegroundColor Yellow
    Write-Host "  -> Verify aws_secret_access_key is 40 chars with no spaces" -ForegroundColor Yellow
    Write-Host "  -> Verify IAM user is active in AWS Console" -ForegroundColor Yellow
} elseif ($testJson -match "AccessDenied") {
    Write-Host "FAILED: IAM user lacks permission." -ForegroundColor Red
    Write-Host "  -> Attach DatadogSecretReaderPolicy to IAM user in AWS Console" -ForegroundColor Yellow
} elseif ($testJson -match "ResourceNotFoundException") {
    Write-Host "FAILED: Secret ARN not found in AWS." -ForegroundColor Red
    Write-Host "  -> Verify secret_id ARN in $yamlDest matches AWS Console" -ForegroundColor Yellow
} elseif ($testJson -match '"error":"') {
    Write-Host "FAILED: Unknown error. See response above." -ForegroundColor Red
} else {
    Write-Host "WARNING: Could not parse backend response." -ForegroundColor Yellow
}


# ============================================================
Write-Host ""
Write-Host "=== Step 8: Verifying Agent Secrets ===" -ForegroundColor Cyan
$secretCheck = & $agentExe secret 2>&1
Write-Output $secretCheck

if ($secretCheck -match "Number of secrets resolved: ([0-9]+)") {
    $count = $Matches[1]
    if ([int]$count -gt 0) {
        Write-Host "PASSED: $count secret(s) resolved by Agent." -ForegroundColor Green
    } else {
        Write-Host "WARNING: Agent running but 0 secrets resolved." -ForegroundColor Yellow
        Write-Host "  -> Fix AWS credentials in $yamlDest and re-run setup.ps1" -ForegroundColor Yellow
    }
}


# ============================================================
Write-Host ""
Write-Host "=== Step 9: Final Permissions Check ===" -ForegroundColor Cyan
Write-Host "EXE Permissions:" -ForegroundColor Yellow
Get-Acl $exeDest  | Select-Object -ExpandProperty Access | Select-Object IdentityReference, FileSystemRights | Format-Table -AutoSize
Write-Host "YAML Permissions:" -ForegroundColor Yellow
Get-Acl $yamlDest | Select-Object -ExpandProperty Access | Select-Object IdentityReference, FileSystemRights | Format-Table -AutoSize


# ============================================================
Write-Host ""
Write-Host "=== SETUP COMPLETE ===" -ForegroundColor Green
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Backend ID : $backendId"  -ForegroundColor White
Write-Host "  API Key Ref: $encRef"     -ForegroundColor White
Write-Host "  EXE        : $exeDest"    -ForegroundColor White
Write-Host "  YAML       : $yamlDest"   -ForegroundColor White
Write-Host "  DD Config  : $ddConfig"   -ForegroundColor White
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. If Step 7 FAILED - fix AWS credentials in $yamlDest and re-run setup.ps1" -ForegroundColor White
Write-Host "  2. If Step 7 PASSED - confirm host appears in Datadog Infrastructure page" -ForegroundColor White
Write-Host "  3. Run: agent.exe status" -ForegroundColor White
Write-Host "  4. Add more ENC[] refs to integration configs as needed" -ForegroundColor White
