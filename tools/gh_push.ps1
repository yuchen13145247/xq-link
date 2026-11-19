param(
    [Parameter(Mandatory = $true)] [string] $Token,
    [Parameter(Mandatory = $true)] [string] $Repo,
    [string] $Branch = "main",
    [string] $Workflow = "ios.yml",
    [string] $OutDir = "$env:USERPROFILE\Desktop"
)

$ErrorActionPreference = "Stop"
$api = "https://api.github.com"
$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "xq-link-builder"
}

function Invoke-GH {
    param([string]$Method, [string]$Url, $Body)
    $p = @{ Method = $Method; Uri = "$api$Url"; Headers = $headers; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $p.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
        $p.ContentType = "application/json"
    }
    $r = Invoke-RestMethod @p
    return $r
}

$parts = $Repo.Split("/")
if ($parts.Count -ne 2) { throw "Repo must be owner/name" }
$owner = $parts[0]; $name = $parts[1]
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $root "project.yml"))) { throw "run from the xq-link project dir" }

Write-Host "==> repo $Repo"
$exists = $true
try { Invoke-GH GET "/repos/$Repo" | Out-Null } catch { $exists = $false }
if (-not $exists) {
    Invoke-GH POST "/user/repos" @{ name = $name; private = $true; auto_init = $false } | Out-Null
    Write-Host "    created private repo"
} else {
    Write-Host "    already exists"
}

Write-Host "==> upload files"
$skipParts = @("/.git/", "/build/", "/engine/pikafish/", "/.github/workflows/")
$files = Get-ChildItem -Path $root -Recurse -File
foreach ($f in $files) {
    $full = $f.FullName.Replace("\", "/")
    $skip = $false
    foreach ($s in $skipParts) { if ($full.Contains($s)) { $skip = $true } }
    if ($skip) { continue }

    $rel = $f.FullName.Substring($root.Length + 1).Replace("\", "/")
    $content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
    $body = @{ message = "add $rel"; content = $content; branch = $Branch }

    $sha = $null
    try { $sha = (Invoke-GH GET "/repos/$Repo/contents/$rel`?ref=$Branch").sha } catch { }
    if ($sha) { $body.sha = $sha }

    Invoke-GH PUT "/repos/$Repo/contents/$rel" $body | Out-Null
    Write-Host "    $rel"
}

$wfLocal = Join-Path $root ".github\workflows\$Workflow"
if (Test-Path $wfLocal) {
    $rel = ".github/workflows/$Workflow"
    Write-Host "==> upload workflow"
    $body = @{
        message = "add workflow"
        content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($wfLocal))
        branch  = $Branch
    }
    $sha = $null
    try { $sha = (Invoke-GH GET "/repos/$Repo/contents/$rel`?ref=$Branch").sha } catch { }
    if ($sha) { $body.sha = $sha }
    Invoke-GH PUT "/repos/$Repo/contents/$rel" $body | Out-Null
}

Write-Host "==> trigger workflow"
$dispatched = $false
for ($try = 0; $try -lt 5 -and -not $dispatched; $try++) {
    try {
        Invoke-GH POST "/repos/$Repo/actions/workflows/$Workflow/dispatches" @{ ref = $Branch } | Out-Null
        $dispatched = $true
    } catch {
        Write-Host "    dispatch retry $try : $($_.Exception.Message)"
        Start-Sleep -Seconds 10
    }
}
if (-not $dispatched) { throw "workflow dispatch failed" }

Start-Sleep -Seconds 10

$runId = $null
for ($i = 0; $i -lt 20 -and -not $runId; $i++) {
    $runs = Invoke-GH GET "/repos/$Repo/actions/runs?per_page=10"
    $cand = $runs.workflow_runs | Where-Object { $_.path -like "*$Workflow*" } | Select-Object -First 1
    if ($cand) { $runId = $cand.id }
    if (-not $runId) { Start-Sleep -Seconds 6 }
}
if (-not $runId) { throw "no workflow run found" }
Write-Host "==> run id = $runId"

$run = $null
for ($i = 0; $i -lt 150; $i++) {
    $run = Invoke-GH GET "/repos/$Repo/actions/runs/$runId"
    Write-Host ("    [{0}] status={1} conclusion={2}" -f $i, $run.status, $run.conclusion)
    if ($run.status -eq "completed") { break }
    Start-Sleep -Seconds 20
}

if ($run.conclusion -ne "success") {
    Write-Host "BUILD FAILED: https://github.com/$Repo/actions/runs/$runId"
    throw "build failed: $($run.conclusion)"
}

Write-Host "==> download artifact"
$arts = Invoke-GH GET "/repos/$Repo/actions/runs/$runId/artifacts"
$art = $arts.artifacts | Select-Object -First 1
if (-not $art) { throw "no artifact" }

$zip = Join-Path $env:TEMP "xq-artifact.zip"
Invoke-WebRequest -Uri $art.archive_download_url -Headers $headers -OutFile $zip -UseBasicParsing
$out = Join-Path $OutDir "XiangqiLink-ipa"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $out -Force

$ipa = Get-ChildItem $out -Recurse -Filter *.ipa | Select-Object -First 1
if (-not $ipa) { throw "no ipa in artifact" }
$dest = Join-Path $OutDir "XiangqiLink.ipa"
Copy-Item $ipa.FullName $dest -Force
Write-Host ("DONE: {0} ({1:N0} bytes)" -f $dest, (Get-Item $dest).Length)
