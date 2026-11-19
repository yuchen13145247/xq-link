# 从本机那份象棋助手 IPA 里抽 pikafish.nnue（本地自测用，CI 不起来的时候用它）
# 用法: powershell -ExecutionPolicy Bypass -File tools\pull_nnue.ps1 -Ipa "C:\path\to\app.ipa"

param(
    [Parameter(Mandatory = $true)] [string] $Ipa,
    [string] $Out = "pikafish.nnue"
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Ipa))
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -like "*assets/nnue/pikafish.nnue" } | Select-Object -First 1
    if (-not $entry) { throw "IPA 里没找到 assets/nnue/pikafish.nnue" }
    $target = Join-Path (Get-Location) $Out
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    "{0}  {1:N0} 字节" -f $target, (Get-Item $target).Length
}
finally {
    $zip.Dispose()
}
