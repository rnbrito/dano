<#
.SYNOPSIS
    Compara arquivos de midia de uma arvore de pastas com os "gemeos" de outra
    arvore, usando o hash de streams do dano.

.DESCRIPTION
    Para cada caminho da lista (um por linha, dentro de RaizA), localiza o gemeo
    em RaizB (mesmo caminho relativo), calcula o hash de streams das duas copias
    com o dano e, quando os hashes diferem, decodifica as duas com o ffmpeg para
    apontar qual copia esta danificada.

    Nada e gravado em P: -- o script apenas le os arquivos.  O relatorio (CSV) e
    os logs de erros do ffmpeg ficam na pasta de saida.

    Este arquivo e propositalmente ASCII puro (sem acentos), para funcionar tanto
    no Windows PowerShell 5.1 quanto no PowerShell 7.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\comparar-gemeos.ps1

.EXAMPLE
    .\comparar-gemeos.ps1 -Lista .\lista.txt -RaizA 'P:\RNB-AV2\' -RaizB 'P:\RNB-AV\'
#>
[CmdletBinding()]
param(
    # arquivo texto com um caminho completo por linha (dentro de RaizA)
    [string]$Lista = (Join-Path $PSScriptRoot 'listagem_em_RNB-AV2.txt'),
    [string]$RaizA = 'P:\RNB-AV2\',
    [string]$RaizB = 'P:\RNB-AV\',
    # pasta onde ficam o relatorio e os logs
    [string]$Saida = (Join-Path $PSScriptRoot 'comparacao'),
    [string]$Dano,
    [string]$Ffmpeg,
    # nao decodificar com o ffmpeg quando os hashes diferirem (mais rapido)
    [switch]$SemDecodificar
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Find-Tool([string]$Explicit, [string]$Name) {
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        throw "Nao encontrei: $Explicit"
    }

    $local = Join-Path $PSScriptRoot "$Name.exe"
    if (Test-Path -LiteralPath $local) { return $local }

    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    throw "Nao encontrei $Name.exe (nem na pasta do script, nem no PATH)."
}

# Executa um programa, devolvendo codigo de saida, stdout e stderr (lidos como UTF-8).
function Invoke-Tool([string]$Exe, [string[]]$Arguments, [string]$WorkDir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $out
        StdErr   = $errTask.Result
    }
}

# Hash de streams via dano.  Usa um arquivo de hashes temporario e exclusivo, para
# nao depender (nem alterar) de nenhum dano_hashes.txt existente.
function Get-DanoHash([string]$Path) {
    $tmp = Join-Path $script:TmpDir ([guid]::NewGuid().ToString() + '.txt')

    try {
        $res = Invoke-Tool $script:DanoExe @('-w', '--disable-filter', '-o', $tmp, $Path) $script:TmpDir

        if (Test-Path -LiteralPath $tmp) {
            foreach ($line in [System.IO.File]::ReadAllLines($tmp, [System.Text.Encoding]::UTF8)) {
                if (-not $line.StartsWith('{')) { continue }

                $record = $line | ConvertFrom-Json
                if ($record.metadata -and $record.metadata.hash_value.value) {
                    return [pscustomobject]@{
                        Hash = ('{0}={1}' -f $record.metadata.hash_algo, $record.metadata.hash_value.value)
                        Erro = $null
                    }
                }
            }
        }

        $msg = ($res.StdErr -split "`r?`n" | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
        if (-not $msg) { $msg = "dano nao gerou hash (codigo de saida $($res.ExitCode))" }
        return [pscustomobject]@{ Hash = $null; Erro = $msg }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Decodifica o arquivo inteiro e devolve a quantidade de linhas de erro do ffmpeg.
function Test-Decode([string]$Path, [string]$LogFile) {
    $res = Invoke-Tool $script:FfmpegExe @('-v', 'error', '-nostdin', '-i', $Path, '-f', 'null', '-') $script:TmpDir
    $lines = @($res.StdErr -split "`r?`n" | Where-Object { $_.Trim() })

    if ($lines.Count -gt 0) {
        [System.IO.File]::WriteAllLines($LogFile, [string[]]$lines, (New-Object System.Text.UTF8Encoding($true)))
    }

    return $lines.Count
}

function Read-Lista([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)

    try {
        # UTF-8 estrito; se falhar, o arquivo esta na pagina de codigo do Windows
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    catch {
        $text = [System.Text.Encoding]::Default.GetString($bytes)
    }

    return @($text.TrimStart([char]0xFEFF) -split "`r?`n" |
        ForEach-Object { $_.Trim().Trim('"') } |
        Where-Object { $_ })
}

function Format-Tamanho($Bytes) {
    if ($null -eq $Bytes) { return '' }
    return ('{0:N0}' -f $Bytes)
}

# --- preparacao ---------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Lista)) { throw "Lista nao encontrada: $Lista" }

$script:DanoExe = Find-Tool $Dano 'dano'
$script:FfmpegExe = if ($SemDecodificar) { $null } else { Find-Tool $Ffmpeg 'ffmpeg' }

if (-not $RaizA.EndsWith('\')) { $RaizA += '\' }
if (-not $RaizB.EndsWith('\')) { $RaizB += '\' }

New-Item -ItemType Directory -Force -Path $Saida | Out-Null
$Saida = (Resolve-Path -LiteralPath $Saida).Path

$script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dano-gemeos-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:TmpDir | Out-Null

$caminhos = Read-Lista $Lista
$total = $caminhos.Count
$resultados = New-Object System.Collections.Generic.List[object]

Write-Host "dano:    $script:DanoExe"
if ($script:FfmpegExe) { Write-Host "ffmpeg:  $script:FfmpegExe" }
Write-Host "Raiz A:  $RaizA"
Write-Host "Raiz B:  $RaizB"
Write-Host "Arquivos na lista: $total"
Write-Host ''

# --- comparacao ---------------------------------------------------------------

try {
    $n = 0
    foreach ($caminhoA in $caminhos) {
        $n++

        $r = [ordered]@{
            N         = $n
            Veredito  = ''
            Relativo  = $caminhoA
            TamanhoA  = $null
            TamanhoB  = $null
            HashA     = ''
            HashB     = ''
            ErrosA    = $null
            ErrosB    = $null
            Detalhe   = ''
        }

        if (-not $caminhoA.StartsWith($RaizA, [System.StringComparison]::OrdinalIgnoreCase)) {
            $r.Veredito = 'FORA DA RAIZ A'
            $r.Detalhe = "o caminho nao comeca com $RaizA"
            $resultados.Add([pscustomobject]$r)
            Write-Host ("[{0}/{1}] {2}`n        -> {3}" -f $n, $total, $caminhoA, $r.Veredito) -ForegroundColor Yellow
            continue
        }

        $relativo = $caminhoA.Substring($RaizA.Length)
        $caminhoB = $RaizB + $relativo
        $r.Relativo = $relativo

        Write-Host ("[{0}/{1}] {2}" -f $n, $total, $relativo)

        $existeA = Test-Path -LiteralPath $caminhoA -PathType Leaf
        $existeB = Test-Path -LiteralPath $caminhoB -PathType Leaf

        if ($existeA) { $r.TamanhoA = (Get-Item -LiteralPath $caminhoA).Length }
        if ($existeB) { $r.TamanhoB = (Get-Item -LiteralPath $caminhoB).Length }

        if (-not $existeA -or -not $existeB) {
            $r.Veredito = if (-not $existeA -and -not $existeB) { 'AUSENTE NAS DUAS' }
                          elseif (-not $existeA) { 'AUSENTE EM A' }
                          else { 'AUSENTE EM B' }
            $resultados.Add([pscustomobject]$r)
            Write-Host "        -> $($r.Veredito)" -ForegroundColor Yellow
            continue
        }

        $hA = Get-DanoHash $caminhoA
        $hB = Get-DanoHash $caminhoB
        $r.HashA = if ($hA.Hash) { $hA.Hash } else { '' }
        $r.HashB = if ($hB.Hash) { $hB.Hash } else { '' }

        if ($hA.Hash -and $hB.Hash -and ($hA.Hash -eq $hB.Hash)) {
            $r.Veredito = 'IGUAIS'
            if ($r.TamanhoA -ne $r.TamanhoB) {
                $r.Detalhe = 'streams identicos, mas tamanho de arquivo diferente (tags/container)'
            }
            $resultados.Add([pscustomobject]$r)
            Write-Host "        -> IGUAIS ($($hA.Hash))" -ForegroundColor Green
            continue
        }

        $detalhes = @()
        if ($hA.Erro) { $detalhes += "dano em A: $($hA.Erro)" }
        if ($hB.Erro) { $detalhes += "dano em B: $($hB.Erro)" }

        if ($SemDecodificar) {
            $r.Veredito = 'DIFERENTES'
        }
        else {
            Write-Host '        hashes diferentes; decodificando as duas copias com o ffmpeg...'
            $prefixo = Join-Path $Saida ('{0:D3}' -f $n)
            $r.ErrosA = Test-Decode $caminhoA "$prefixo-A-erros.txt"
            $r.ErrosB = Test-Decode $caminhoB "$prefixo-B-erros.txt"

            $r.Veredito = if ($r.ErrosA -eq 0 -and $r.ErrosB -gt 0) { 'DIFERENTES: B DANIFICADA' }
                          elseif ($r.ErrosA -gt 0 -and $r.ErrosB -eq 0) { 'DIFERENTES: A DANIFICADA' }
                          elseif ($r.ErrosA -gt 0 -and $r.ErrosB -gt 0) { 'DIFERENTES: AMBAS COM ERROS' }
                          else { 'DIFERENTES: SEM ERROS DE DECODIFICACAO' }
        }

        $r.Detalhe = ($detalhes -join ' | ')
        $resultados.Add([pscustomobject]$r)
        Write-Host "        -> $($r.Veredito)" -ForegroundColor Red
    }
}
finally {
    Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- relatorio ----------------------------------------------------------------

$csv = Join-Path $Saida 'relatorio.csv'
$resultados | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -Delimiter ';'

Write-Host ''
Write-Host '================ RESUMO ================'
$resultados | Group-Object Veredito | Sort-Object Name | ForEach-Object {
    Write-Host ('{0,3}  {1}' -f $_.Count, $_.Name)
}

$problemas = @($resultados | Where-Object { $_.Veredito -ne 'IGUAIS' })
if ($problemas.Count -gt 0) {
    Write-Host ''
    Write-Host 'Arquivos que NAO sao iguais:'
    foreach ($p in $problemas) {
        Write-Host ('  [{0}] {1}' -f $p.Veredito, $p.Relativo)
        if ($null -ne $p.ErrosA) {
            Write-Host ('        erros de decodificacao: A={0}  B={1}   tamanho: A={2}  B={3}' -f `
                $p.ErrosA, $p.ErrosB, (Format-Tamanho $p.TamanhoA), (Format-Tamanho $p.TamanhoB))
        }
        if ($p.Detalhe) { Write-Host "        $($p.Detalhe)" }
    }
}

Write-Host ''
Write-Host "Relatorio: $csv"
Write-Host "Logs de erros do ffmpeg (quando houver): $Saida"
