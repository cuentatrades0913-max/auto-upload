<#
.SYNOPSIS
    Auto-Upload: indexa/busca un archivo, lo sube a GitHub (API REST) y avisa por Discord.
    Disenado para ejecutarse via: irm <URL> | iex
    Las credenciales se toman de variables de entorno (GH_TOKEN, GH_REPO, GH_WEBHOOK)
    definidas en el MISMO one-liner, asi el repositorio no contiene secretos.
.PARAMETER FileName      Nombre o parte del nombre del archivo a buscar.
.PARAMETER SearchRoot    Carpeta raiz de busqueda. Default: C:\Bastisss
.PARAMETER Token         PAT de GitHub. Default: $env:GH_TOKEN
.PARAMETER Repo          Repositorio destino "user/repo". Default: $env:GH_REPO
.PARAMETER Branch        Branch destino. Default: main (se auto-detecta).
.PARAMETER WebhookUrl    URL webhook Discord. Default: $env:GH_WEBHOOK
#>
[CmdletBinding()]
param(
    [string]$FileName   = "ESTE ARCHIVO SUBI PARA PROBAR.txt",
    [string]$SearchRoot = "C:\Bastisss",
    [string]$Token      = $env:GH_TOKEN,
    [string]$Repo       = $env:GH_REPO,
    [string]$Branch     = "main",
    [string]$WebhookUrl = $env:GH_WEBHOOK,
    [string]$CommitMsg  = "Auto-upload: subida automatica desde equipo remoto",
    [int]$RecurseDepth  = 6
)

# ---------- Validacion ----------
$missing = @()
if (-not $Token)      { $missing += 'GH_TOKEN (token de GitHub)' }
if (-not $Repo)       { $missing += 'GH_REPO (user/repo)' }
if (-not $WebhookUrl) { $missing += 'GH_WEBHOOK (url de Discord)' }
if ($missing) {
    Write-Host "[ERROR] Faltan variables de entorno:" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  - $m" -ForegroundColor Yellow }
    Write-Host "Definilas en el mismo one-liner, ej:" -ForegroundColor Cyan
    Write-Host '  $env:GH_TOKEN="ghp_xxx"; $env:GH_REPO="user/repo"; $env:GH_WEBHOOK="https://discord.com/api/webhooks/..."; irm <URL> | iex' -ForegroundColor Gray
    exit 1
}

# ---------- Helpers ----------
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

    $desc = if ($Status -eq 'SUCCESS') {
        "**$emoji Subida completada correctamente**`n`n" +
        "**Equipo:** ``$ComputerName```n" +
        "**Archivo:** ``$FilePath```n" +
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
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        Invoke-RestMethod -Uri $HookUrl -Method Post `
            -ContentType 'application/json' -Body $payload `
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

# ---------- Principal ----------
$ErrorActionPreference = 'Stop'
$script:ComputerName   = $env:COMPUTERNAME
$script:FinalStatus    = 'ERROR'
$script:FoundPath      = ""
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

    # 2) Resolver branch destino
    $Branch = Get-GitHubDefaultBranch -RepoOwnerSlashName $Repo -TokenName $Token
    Write-Log "Branch destino: $Branch" "Cyan"

    # 3) Leer archivo y convertir a base64
    $bytes  = [System.IO.File]::ReadAllBytes($script:FoundPath)
    $b64    = [Convert]::ToBase64String($bytes)
    $target = Split-Path $script:FoundPath -Leaf
    Write-Log "Tamano archivo: $($bytes.Length) bytes" "Cyan"

    # 4) Comprobar si ya existe (para sha correcto en update)
    $apiBase = "https://api.github.com/repos/$Repo/contents/$target"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $existingSha = $null
    try {
        $resp = Invoke-RestMethod -Uri "$apiBase?ref=$Branch" -Headers $headers `
            -ErrorAction Stop -SkipHttpErrorCheck
        if ($resp.sha) { $existingSha = $resp.sha }
    } catch {}

    $body = @{
        message = $CommitMsg
        content = $b64
        branch  = $Branch
    }
    if ($existingSha) { $body.sha = $existingSha }
    $bodyJson = $body | ConvertTo-Json -Depth 5

    # 5) PUT para crear/actualizar el archivo
    Write-Log "Subiendo a GitHub: $Repo / $target (branch $Branch)" "Yellow"
    $putResp = Invoke-RestMethod -Method Put -Uri "$apiBase" -Headers $headers `
        -Body $bodyJson -ContentType 'application/json' -ErrorAction Stop

    $script:CommitShaFinal = $putResp.content.sha
    $script:FinalStatus    = 'SUCCESS'
    Write-Log "OK: archivo subido. Commit SHA=$($script:CommitShaFinal)" "Green"

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
        -FilePath $script:FoundPath `
        -CommitSha $script:CommitShaFinal `
        -RepoName $Repo `
        -BranchName $Branch `
        -Extra $script:LastError
    Write-Log "=== Fin ===" "Green"
}
