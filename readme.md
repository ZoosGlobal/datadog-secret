# Datadog Secret Backend - AWS Secrets Manager

Automates secure API key injection into the Datadog Agent using AWS Secrets Manager `ENC[]` references. Zero plaintext credentials on disk.

---

## What This Does

The Datadog Agent requires an API key in `datadog.yaml`. Storing it as plaintext is a security risk. This setup installs a secret backend binary that fetches the API key from AWS Secrets Manager at runtime.

```
Agent starts
  -> reads ENC[all_secrets:api_key] in datadog.yaml
  -> calls datadog-secret-backend.exe
  -> exe fetches secret from AWS Secrets Manager
  -> returns decrypted api_key to Agent in memory
  -> Agent connects to Datadog
```

---

## Folder Structure

```
your\folder\location\
|-- setup.ps1                    # Run this as Administrator
|-- datadog-secret-backend.exe   # Secret backend binary
|-- datadog-secret-backend.yaml  # AWS credentials + secret ARN (never commit)
└-- README.md
```

After running `setup.ps1`, files are installed to:

```
C:\Program Files\datadog-secret-backend\
|-- datadog-secret-backend.exe   # copied with locked permissions
└-- datadog-secret-backend.yaml  # copied with locked permissions
```

---

## Prerequisites

- Datadog Agent installed at `C:\Program Files\Datadog\Datadog Agent\`
- Config file exists at `C:\ProgramData\Datadog\datadog.yaml`
- AWS Console access to create secrets and IAM users
- PowerShell 5.1+ — check with `$PSVersionTable.PSVersion`
- PowerShell open as **Administrator**

---

## Step 1 - Create the Secret in AWS Secrets Manager

1. Open https://console.aws.amazon.com/secretsmanager
2. Click **Store a new secret**
3. Select **Other type of secret**
4. Add key/value pair:
   - Key: `api_key`
   - Value: your Datadog API key (from https://app.datadoghq.com/organization-settings/api-keys)
5. Click **Next**
6. Secret name: `datadog/api_key`
7. Click **Next -> Next -> Store**
8. **Copy the full Secret ARN** from the confirmation page

The ARN looks like:

```
arn:aws:secretsmanager:ap-south-1:993458096335:secret:datadog/api_key-AbCdEf
```

> The trailing `-AbCdEf` suffix is part of the ARN. Include it in full.

---

## Step 2 - Create IAM User with Read Permission

1. Open https://console.aws.amazon.com/iam
2. Go to **Users -> Create user**
3. Username: `datadog-secret-reader` (do NOT enable console access)
4. Click **Next -> Next -> Create user**
5. Open the user -> **Add permissions -> Create inline policy**
6. Switch to JSON tab and paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:ap-south-1:993458096335:secret:*"
    }
  ]
}
```

7. Policy name: `DatadogSecretReaderPolicy` -> **Create policy**
8. Go to user -> **Security credentials** tab
9. Click **Create access key** -> Use case: **Other** -> Next -> **Create access key**
10. Click **Download .csv file**

> The secret access key is shown ONLY ONCE. Always copy from the CSV file, never from the browser screen.

You will have:
- `aws_access_key_id` — 20 characters, starts with AKIA
- `aws_secret_access_key` — 40 characters

---

## Step 3 - Configure datadog-secret-backend.yaml

Open `your\folder\location\datadog-secret-backend.yaml` and fill in:

```yaml
backends:
  all_secrets:
    backend: aws_secrets_manager
    aws_access_key_id: xxxxx
    aws_secret_access_key: dvsdf
    aws_region: ap-south-1
    secret_id: arn:aws:secretsmanager:ap-south-1:99345809856335:secret:datadog/api_key-AbCdEf
```

Rules:
- `aws_access_key_id` — exactly 20 chars, starts with AKIA, no quotes
- `aws_secret_access_key` — exactly 40 chars, no spaces, no quotes
- `aws_region` — must match the region where the secret was created
- `secret_id` — full ARN including the trailing suffix

> Never commit this file. Add `datadog-secret-backend.yaml` to `.gitignore`.

---

## Step 4 - Run Setup Script

Open **PowerShell as Administrator** and run:

```powershell
cd your\folder\location\
.\setup.ps1
```

### What setup.ps1 Does

| Step | Action |
| --- | --- |
| Pre-flight | Confirms exe and yaml exist, Agent installed, no placeholder values |
| Step 1 | Creates `C:\Program Files\datadog-secret-backend\` |
| Step 2 | Copies exe and yaml to install directory |
| Step 3 | Sets EXE permissions — SYSTEM: FullControl, ddagentuser: ReadAndExecute |
| Step 4 | Sets YAML permissions — SYSTEM: FullControl, ddagentuser: ReadAndExecute |
| Step 5 | Injects `api_key` and `secret_backend_command` into `datadog.yaml` |
| Step 6 | Stops and restarts Datadog Agent service |
| Step 7 | Tests backend binary directly — PASS if response has `error: null` |
| Step 8 | Runs `agent.exe secret` — confirms 1 secret resolved |
| Step 9 | Prints final ACL permissions for both installed files |

> Fully idempotent — safe to re-run at any time.

---

## Step 5 - Verify the Setup

```powershell
# Check Agent service
Get-Service DatadogAgent

# Check secrets resolved
& "C:\Program Files\Datadog\Datadog Agent\bin\agent.exe" secret

# Full Agent health
& "C:\Program Files\Datadog\Datadog Agent\bin\agent.exe" status
```

Expected from `agent.exe secret`:

```
=== Secrets stats ===
Number of secrets resolved: 1
Secrets handle decoding:
- 'all_secrets:api_key': resolved
```

Check Datadog UI — host appears within 2-3 minutes:
https://app.datadoghq.com/infrastructure

---

## Step 6 - Manual Backend Test

```powershell
$test = '{"version": "1.0", "secrets": ["all_secrets:api_key"]}'
$test | & "C:\Program Files\datadog-secret-backend\datadog-secret-backend.exe"
```

Expected response:

```json
{"all_secrets:api_key": {"value": "dd_api_key_xxxxxxxx", "error": null}}
```

If `error` is `null` — credentials and ARN are correct. Any other value — fix before re-running `setup.ps1`.

---

## Step 7 - Adding More Secrets (Optional)

Any Datadog integration config can use `ENC[]` references once the backend is working.

Example — MySQL integration:

```yaml
init_config:
instances:
  - host: 127.0.0.1
    username: datadog
    password: ENC[all_secrets:mysql_password]
```

To add `mysql_password`:
1. Secrets Manager -> open your secret -> **Edit secret value**
2. Add row: Key = `mysql_password`, Value = your password
3. Save — no changes to `setup.ps1` or yaml needed

---

## How datadog.yaml Is Modified

Two targeted injections — each key placed in its correct section:

**Injection 1 — api_key at line ~5 (Basic Configuration)**

```yaml
# @param api_key - string - required
api_key: ENC[all_secrets:api_key]
# @env DD_API_KEY - string - required
```

**Injection 2 — secret_backend_command at line ~870 (Secrets section)**

```yaml
# @param secret_backend_type - string - optional
secret_backend_command: C:\Program Files\datadog-secret-backend\datadog-secret-backend.exe
# @env DD_SECRET_BACKEND_TYPE - string - optional
```

> `secret_backend_command` belongs in the Secrets section — placing it near `api_key` causes Agent parse errors.
> All existing lines are stripped before re-injection. No duplicates guaranteed.

---

## File Permissions

| File | SYSTEM | Administrators | ddagentuser |
| --- | --- | --- | --- |
| datadog-secret-backend.exe | FullControl | FullControl | ReadAndExecute |
| datadog-secret-backend.yaml | FullControl | FullControl | ReadAndExecute |

`ddagentuser` is the Windows service account for the Datadog Agent. Without `ReadAndExecute` on both files the Agent cannot call the backend.

---

## Troubleshooting

### UnrecognizedClientException

AWS credentials are invalid.

- `aws_access_key_id` must be exactly 20 chars starting with `AKIA`
- `aws_secret_access_key` must be exactly 40 chars with no spaces
- Confirm IAM user belongs to account `993458096335`
- Create a fresh key and copy from the downloaded CSV only

Check key lengths:

```powershell
$y = Get-Content "C:\Program Files\datadog-secret-backend\datadog-secret-backend.yaml"
$k = (($y | Select-String "aws_access_key_id:").Line -replace ".*aws_access_key_id:\s*","").Trim()
$s = (($y | Select-String "aws_secret_access_key:").Line -replace ".*aws_secret_access_key:\s*","").Trim()
Write-Host "Key: $($k.Length) chars (must be 20)"
Write-Host "Sec: $($s.Length) chars (must be 40)"
```

### AccessDenied

IAM user is missing permission. Attach `GetSecretValue` inline policy (see Step 2) and re-run `setup.ps1`.

### ResourceNotFoundException

Secret ARN is wrong. Copy the full ARN from Secrets Manager including the trailing suffix e.g. `-AbCdEf`. Update `secret_id` in yaml and re-run `setup.ps1`.

### Agent Not Starting

```powershell
# Check logs
Get-Content "C:\ProgramData\Datadog\logs\agent.log" -Tail 50

# Check for duplicate keys
Get-Content "C:\ProgramData\Datadog\datadog.yaml" | Select-String "^api_key:|^secret_backend_command:"
```

Should show exactly 1 of each. Re-run `setup.ps1` to fix.

### 0 Secrets Resolved

- Run manual test (Step 6) to see exact error
- Confirm secret key name in AWS is exactly `api_key`
- Confirm `$backendId = "all_secrets"` in setup.ps1 matches `backends: all_secrets:` in yaml

### Parse Errors Running setup.ps1

Never copy-paste `.ps1` files from a browser or chat. Browsers convert straight quotes to curly quotes which break PowerShell. Always use the **downloaded file** directly.

### Host Not in Datadog UI

Wait 5 minutes then check `agent.exe status`. Verify `site:` in `datadog.yaml` matches your account:
- `ap1.datadoghq.com` for AP1
- `datadoghq.com` for US1
- `datadoghq.eu` for EU

---

## Production Checklist

**AWS**
- [ ] Secret created with key named exactly `api_key`
- [ ] Full ARN copied including trailing suffix
- [ ] IAM user `datadog-secret-reader` created
- [ ] `GetSecretValue` policy attached
- [ ] Access key downloaded as CSV

**Local Config**
- [ ] `datadog-secret-backend.yaml` has no placeholder values
- [ ] `aws_access_key_id` is 20 chars starting with `AKIA`
- [ ] `aws_secret_access_key` is 40 chars, no spaces
- [ ] `aws_region` matches secret region
- [ ] `secret_id` is full ARN with trailing suffix
- [ ] File added to `.gitignore`

**Setup Script**
- [ ] `setup.ps1` run as Administrator
- [ ] All steps completed with no RED errors
- [ ] Step 7 PASSED — shows `error: null`
- [ ] Step 8 shows `Number of secrets resolved: 1`

**Verification**
- [ ] `Get-Service DatadogAgent` shows Running
- [ ] `agent.exe secret` shows 1 resolved
- [ ] `agent.exe status` shows API Key valid
- [ ] Host visible at https://app.datadoghq.com/infrastructure
- [ ] No plaintext `api_key` in `datadog.yaml`

---

## Quick Reference

```powershell
# Restart Agent
net stop datadogagent && net start datadogagent

# Check Agent status
& "C:\Program Files\Datadog\Datadog Agent\bin\agent.exe" status

# Check secrets
& "C:\Program Files\Datadog\Datadog Agent\bin\agent.exe" secret

# Test backend manually
$t = '{"version": "1.0", "secrets": ["all_secrets:api_key"]}'
$t | & "C:\Program Files\datadog-secret-backend\datadog-secret-backend.exe"

# View Agent logs
Get-Content "C:\ProgramData\Datadog\logs\agent.log" -Tail 100

# Check injections in datadog.yaml
Get-Content "C:\ProgramData\Datadog\datadog.yaml" | Select-String "^api_key:|^secret_backend_command:"

# Re-run full setup
cd your\folder\location\ && .\setup.ps1
```

---

## Security Summary

| Practice | Status |
| --- | --- |
| API key never stored in plaintext on disk | Yes |
| Credentials file excluded from version control | Yes |
| Least-privilege IAM policy — single action only | Yes |
| Backend EXE locked to SYSTEM and ddagentuser | Yes |
| Credentials YAML locked to SYSTEM and ddagentuser | Yes |
| ENC[] references resolved at runtime, never persisted | Yes |

**To rotate credentials if compromised:**
1. IAM -> `datadog-secret-reader` -> Security credentials -> deactivate old key
2. Create new access key -> Download CSV
3. Update `datadog-secret-backend.yaml` with new values
4. Re-run `setup.ps1`

---

Version: 1.0.0 | Last Updated: March 2026