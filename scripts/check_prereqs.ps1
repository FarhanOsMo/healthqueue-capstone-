<#
.SYNOPSIS
  Read-only environment check for Windows PowerShell. Nothing is installed or changed.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\check_prereqs.ps1
#>
$tools = [ordered]@{
  python  = { python --version 2>&1 }
  docker  = { docker --version 2>&1 }
  kind    = { kind version 2>&1 }
  kubectl = { (kubectl version --client 2>&1 | Select-Object -First 1) }
  tofu    = { (tofu version 2>&1 | Select-Object -First 1) }
  git     = { git --version 2>&1 }
}
Write-Output "HealthQueue prerequisite check (Windows $([Environment]::OSVersion.Version), $env:PROCESSOR_ARCHITECTURE)`n"
Write-Output "Tools:"
$found = @{}
foreach ($t in $tools.Keys) {
  if (Get-Command $t -ErrorAction SilentlyContinue) {
    $found[$t] = $true
    Write-Output ("  {0,-10} found    {1}" -f $t, (& $tools[$t]))
  } else {
    $found[$t] = $false
    Write-Output ("  {0,-10} MISSING  see docs/COST_AND_PREREQUISITES.md (winget install ...)" -f $t)
  }
}
$pathA = $false
if ($found.python) {
  python -c "import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)"
  $pathA = ($LASTEXITCODE -eq 0)
  if (-not $pathA) { Write-Output "  ! Python 3.12+ is required (3.13 recommended)." }
}
$dockerUp = $false
if ($found.docker) {
  docker info *> $null
  $dockerUp = ($LASTEXITCODE -eq 0)
  if ($dockerUp) {
    $mem = [int64](docker info --format '{{.MemTotal}}')
    $cpu = docker info --format '{{.NCPU}}'
    Write-Output ("`nDocker engine: running, {0} CPUs, {1:N1} GiB for containers" -f $cpu, ($mem / 1GB))
    if ($mem -lt 4GB) { Write-Output "  ! Less than 4 GiB for Docker: the kind + Argo CD path may be slow or fail." }
  } else {
    Write-Output "`nDocker is installed but the engine is NOT running - start Docker Desktop."
  }
}
$drive = (Get-Location).Drive
Write-Output ("`nFree disk on {0}: {1:N0} GB (need ~6 GB for images on the full path)" -f $drive.Name, ($drive.Free / 1GB))
Write-Output "`nWhat you can run:"
Write-Output ("  Path A (Python: API + tests + workbooks) ........ {0}" -f $(if ($pathA) { "yes" } else { "no" }))
Write-Output ("  Path B (Docker: build, scan, sign, Compose) ..... {0}" -f $(if ($dockerUp) { "yes" } else { "no" }))
Write-Output ("  Path C (kind + Argo CD GitOps) .................. {0}" -f $(if ($dockerUp -and $found.kind -and $found.kubectl) { "yes (run the .sh scripts from Git Bash)" } else { "no" }))
Write-Output ("  OpenTofu validate/plan ......................... {0}" -f $(if ($found.tofu) { "yes" } else { "no" }))
Write-Output "`nReminder: the default workflow needs NO cloud account and NO credentials."
