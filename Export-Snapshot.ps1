# Requires PowerShell 7.4+ for byte-preserving native stdout redirection.
# Export from the existing Docker Desktop installation during a quiet window.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PrivateBackupDirectory,
    [Parameter(Mandatory)]
    [guid]$ProjectWorkspaceId,
    [int]$ExpectedProjectTargets = 128
)

#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

docker version --format '{{.Server.Version}}' | Out-Null
$parent = Get-Item -LiteralPath $PrivateBackupDirectory
if (-not ($parent -is [IO.DirectoryInfo])) {
    throw 'PrivateBackupDirectory must be an existing local directory.'
}

$workspaceId = $ProjectWorkspaceId.ToString()
$countsArgs = @('exec', '-i', 'oasm-postgres', 'psql', '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
    '-v', "project_workspace_id=$workspaceId", '-U', 'postgres', '-d', 'open_asm')

$stack = @(docker ps --filter 'label=com.docker.compose.project=oasm-docker' --format '{{.Names}}')
$connectors = @(docker ps --filter 'network=oasm_connectors' --format '{{.Names}}')
$workers = @($stack | Where-Object { $_ -like 'oasm-docker-oasm-worker-*' })
if (($stack -contains 'oasm-api') -or ($stack -contains 'oasm-rustfs') -or
    ($stack -contains 'oasm-redis') -or $workers.Count -ne 0 -or
    $connectors.Count -ne 0) {
    throw 'Stop API, worker, RustFS and Redis during the maintenance window and confirm there is no running connector.'
}
if ($stack -notcontains 'oasm-postgres') {
    throw 'The source oasm-postgres container must be running.'
}

$imageIds = [ordered]@{
    'local/oasm-api:poc-2e12e49' = 'sha256:a93a128528c02b0acbb46902e27e62a2c56479fe12df0a3892492325e7125042'
    'local/oasm-console:poc-2e12e49' = 'sha256:d31b06be08d760220fa6ce1b123e6c2e9eddcd121c9338793dd3d3190550b154'
    'local/oasm-worker:poc-2e12e49' = 'sha256:41bddaf7ac68e55065eaa09e2799e18b4209c8291f27200786751be07966f426'
}
foreach ($image in $imageIds.GetEnumerator()) {
    $actual = docker image inspect --format '{{.Id}}' $image.Key
    if ($actual -ne $image.Value) {
        throw "Unexpected image ID for $($image.Key). Record the active source image before exporting."
    }
}

$volumeNames = @('rustfs-data', 'audit-archive', 'redis-data', 'worker-state')
foreach ($volumeName in $volumeNames) {
    docker volume inspect --format '{{.Name}}' "oasm-docker_$volumeName" | Out-Null
}

$counts = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'counts.sql') -Raw |
    docker @countsArgs)
if ($counts -notcontains "targets_in_project_workspace=$ExpectedProjectTargets") {
    throw "Target count differs from the expected $ExpectedProjectTargets. Verify the source workspace before exporting."
}

$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$snapshot = Join-Path $parent.FullName "oasm-snapshot-$stamp"
New-Item -ItemType Directory -Path $snapshot -ErrorAction Stop | Out-Null
$counts | Set-Content -LiteralPath (Join-Path $snapshot 'counts.txt') -Encoding ascii
[IO.File]::WriteAllText((Join-Path $snapshot 'workspace-id.txt'), "$workspaceId`n")

docker exec oasm-postgres pg_dump -U postgres -d open_asm -Fc > (Join-Path $snapshot 'postgres.dump')
$after = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'counts.sql') -Raw |
    docker @countsArgs)
if (Compare-Object $counts $after) {
    throw 'Source row counts changed during export. Quiesce writers and take a new snapshot.'
}

$archiveImage = 'postgres@sha256:2ea8630df176ad090ec92136dee850397c5af8781e4bcf2e4162593691c61bbc'
foreach ($volumeName in $volumeNames) {
    docker run --rm --pull never --network none --read-only --user 0 --entrypoint tar `
        --mount "type=volume,source=oasm-docker_$volumeName,target=/source,readonly" `
        $archiveImage -czf - -C /source . > (Join-Path $snapshot "$volumeName.tar.gz")
    tar.exe -tzf (Join-Path $snapshot "$volumeName.tar.gz") | Out-Null
}

$imageTags = @($imageIds.Keys)
docker image save --output (Join-Path $snapshot 'oasm-images.tar') @imageTags
$files = Get-ChildItem -LiteralPath $snapshot -File | Sort-Object Name
$hashLines = foreach ($file in $files) {
    $sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$sha  $($file.Name)"
}
[IO.File]::WriteAllText((Join-Path $snapshot 'SHA256SUMS'), ($hashLines -join "`n") + "`n")
Write-Output "Snapshot ready: $snapshot"
