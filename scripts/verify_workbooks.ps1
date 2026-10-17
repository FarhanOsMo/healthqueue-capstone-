<#
.SYNOPSIS
  Recalculate the report workbooks in Microsoft Excel and verify them.

.DESCRIPTION
  For each workbook: open in a hidden Excel instance, force a full
  recalculation, scan every used cell on every sheet for formula errors
  (#DIV/0!, #N/A, #NAME?, #REF!, #VALUE!, #NUM!, #NULL!), read the overall result
  of the "Checks" sheet, and save so the file also carries cached values for
  viewers that do not calculate. Exits 1 if anything fails.

  Optional - Windows + Excel only. On other systems open the files in
  LibreOffice Calc (free) or run: python scripts/verify_workbooks.py
  (structure + independent Python recalculation, no Excel needed).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/verify_workbooks.ps1
#>
param(
  [string[]]$Workbooks = @("reports/slo-error-budget.xlsx", "reports/dora-analysis.xlsx"),
  [switch]$NoSave
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
$failed = $false
try {
  foreach ($rel in $Workbooks) {
    $path = Join-Path $root $rel
    if (-not (Test-Path $path)) { Write-Output "MISSING  $rel"; $failed = $true; continue }
    $wb = $excel.Workbooks.Open((Resolve-Path $path).Path)
    $excel.CalculateFull()
    $formulas = 0; $errors = @()
    foreach ($ws in $wb.Worksheets) {
      $used = $ws.UsedRange
      $vals = $used.Value2
      $forms = $used.Formula
      if ($vals -isnot [System.Array]) { continue }
      $rows = $vals.GetLength(0); $cols = $vals.GetLength(1)
      for ($r = 1; $r -le $rows; $r++) {
        for ($c = 1; $c -le $cols; $c++) {
          $f = $forms[$r, $c]
          if ($f -is [string] -and $f.StartsWith("=")) { $formulas++ }
          if ($vals[$r, $c] -is [int]) {   # Excel returns error values as Int32 codes
            $addr = $used.Cells.Item($r, $c).Address($false, $false)
            $errors += "$($ws.Name)!$addr = $($used.Cells.Item($r, $c).Text)"
          }
        }
      }
    }
    $checks = $wb.Worksheets.Item("Checks").Range("B3").Text
    $status = if ($errors.Count -eq 0 -and $checks -eq "ALL CHECKS PASS") { "PASS" } else { "FAIL" }
    if ($status -eq "FAIL") { $failed = $true }
    Write-Output ("{0,-5} {1}  formulas={2}  formula_errors={3}  checks='{4}'  excel={5}" -f $status, $rel, $formulas, $errors.Count, $checks, $excel.Version)
    $errors | Select-Object -First 20 | ForEach-Object { Write-Output "      $_" }
    if (-not $NoSave) { $wb.Save() }
    $wb.Close($false)
  }
}
finally {
  $excel.Quit()
  [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
}
if ($failed) { exit 1 }
