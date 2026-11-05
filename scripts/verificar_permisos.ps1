<#
.SYNOPSIS
    Comprueba que una tabla de BigQuery termine con los mismos accesos que tenía al inicio.
    Solo lectura: no cambia ningún permiso. Versión genérica, para cualquier proyecto, dataset y tabla.

.DESCRIPTION
    Compara dos niveles de acceso:
      1. Permisos de la TABLA (bq get-iam-policy).
      2. Accesos del DATASET (bq show).
    Un READER en el dataset con condición resource.name == ".../tables/<Tabla>" cuenta como
    equivalente a un dataViewer puesto en la tabla.

    -Fase antes   : guarda la foto en salida_permisos\<Proyecto>.<Dataset>.<Referencia>_*.txt
    -Fase despues : compara -Tabla contra la foto de -Referencia (por defecto, la misma tabla).
                    Sale con código 1 si falta algún permiso.

.EXAMPLE
    .\verificar_permisos.ps1 -Fase antes   -Proyecto brokers-main-prod -Dataset co_habi_brokers -Tabla broker_activity
    .\verificar_permisos.ps1 -Fase despues -Proyecto brokers-main-prod -Dataset co_habi_brokers -Tabla broker_activity
    # La tabla nueva, antes de la ventana, contra la foto de la original:
    .\verificar_permisos.ps1 -Fase despues -Proyecto brokers-main-prod -Dataset co_habi_brokers -Tabla broker_activity_nueva -Referencia broker_activity
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('antes', 'despues')] [string] $Fase,
    [Parameter(Mandatory = $true)] [string] $Proyecto,
    [Parameter(Mandatory = $true)] [string] $Dataset,
    [Parameter(Mandatory = $true)] [string] $Tabla,
    [string] $Referencia = '',
    [switch] $Sobrescribir
)
$ErrorActionPreference = 'Stop'
$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'   # arreglo de IPv6 de esta máquina
if (-not $Referencia) { $Referencia = $Tabla }

$Dir      = Join-Path $PSScriptRoot 'salida_permisos'
New-Item -ItemType Directory -Force $Dir | Out-Null
$ArchTabla   = Join-Path $Dir "$Proyecto.$Dataset.${Referencia}_tabla.txt"
$ArchDataset = Join-Path $Dir "$Proyecto.$Dataset.${Referencia}_dataset.txt"

function Get-PermisosTabla([string]$NombreTabla) {
    $ref = "${Proyecto}:${Dataset}.${NombreTabla}"
    $txt = cmd /c "bq get-iam-policy --format=json $ref 2>&1" | Out-String
    if ($LASTEXITCODE -ne 0) { throw "No se pudo leer el IAM de ${ref}: $txt" }
    $pol = $txt | ConvertFrom-Json
    @($pol.bindings | Where-Object { $_ } | ForEach-Object {
        $rol = $_.role
        $_.members | ForEach-Object { "$rol | $_" }
    }) | Sort-Object
}

function Get-AccesosDataset {
    $txt = cmd /c "bq show --format=json ${Proyecto}:${Dataset} 2>&1" | Out-String
    if ($LASTEXITCODE -ne 0) { throw "No se pudo leer el dataset ${Proyecto}:${Dataset}: $txt" }
    $ds = $txt | ConvertFrom-Json
    @($ds.access | ForEach-Object {
        $e = $_
        $otros = $e.PSObject.Properties | Where-Object { $_.Name -ne 'role' } | ForEach-Object {
            $v = if ($_.Value -is [string]) { $_.Value } else { $_.Value | ConvertTo-Json -Compress -Depth 5 }
            "$($_.Name)=$v"
        }
        "$($e.role) | $($otros -join ', ')"
    }) | Sort-Object
}

function Write-Ok([string]$m)    { Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Falla([string]$m) { Write-Host "  FALTA $m" -ForegroundColor Red }
function Write-Aviso([string]$m) { Write-Host "  SOBRA $m" -ForegroundColor Yellow }

# =============================================================================
if ($Fase -eq 'antes') {
    if ((Test-Path $ArchTabla) -and -not $Sobrescribir) {
        throw "Ya existe una foto en $Dir. Usa -Sobrescribir si quieres reemplazarla."
    }
    $t = Get-PermisosTabla $Tabla
    $d = Get-AccesosDataset
    $sello = "# Foto tomada $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC de ${Proyecto}:${Dataset}.${Tabla}"
    @($sello) + $t | Out-File -Encoding utf8 $ArchTabla
    @($sello) + $d | Out-File -Encoding utf8 $ArchDataset
    Write-Host "`nPermisos de la tabla ${Tabla} ($($t.Count)):" -ForegroundColor Cyan
    $t | ForEach-Object { "  $_" }
    Write-Host "`nAccesos del dataset ${Dataset}: $($d.Count) entradas" -ForegroundColor Cyan
    Write-Host "`nFoto guardada en $Dir" -ForegroundColor Green
    exit 0
}

# =============================================================================
if (-not (Test-Path $ArchTabla)) { throw "No hay foto de antes: corre primero .\verificar_permisos.ps1 -Fase antes" }
$antesTabla   = @(Get-Content $ArchTabla   -Encoding utf8 | Where-Object { $_ -and -not $_.StartsWith('#') })
$antesDataset = @(Get-Content $ArchDataset -Encoding utf8 | Where-Object { $_ -and -not $_.StartsWith('#') })
$ahoraTabla   = @(Get-PermisosTabla $Tabla)
$ahoraDataset = @(Get-AccesosDataset)
$fallas = 0

# Accesos de lectura del dataset limitados por condición a ESTA tabla (resource.name == .../tables/<Tabla>).
# Dan el mismo efecto que un dataViewer puesto directamente en la tabla.
$dsJson = cmd /c "bq show --format=json ${Proyecto}:${Dataset} 2>&1" | Out-String | ConvertFrom-Json
$patronTabla = "datasets/$Dataset/tables/$Tabla`""
$equivalentes = @{}
foreach ($e in @($dsJson.access)) {
    if ($e.role -ne 'READER' -or -not $e.condition) { continue }
    if ($e.condition.expression -notlike "*$patronTabla*") { continue }
    $correo = if ($e.userByEmail) { $e.userByEmail } elseif ($e.groupByEmail) { $e.groupByEmail } else { $null }
    if ($correo) { $equivalentes[$correo.ToLower()] = $e.condition.title }
}
function Get-Correo([string]$Permiso) { (($Permiso -split '\|')[1].Trim() -replace '^(user|serviceAccount|group):', '').ToLower() }

Write-Host "`n== Permisos de la tabla ${Tabla} (foto: $((Get-Content $ArchTabla -TotalCount 1).TrimStart('# ')))" -ForegroundColor Cyan
$cubiertosPorDataset = @()
foreach ($p in $antesTabla) {
    if ($ahoraTabla -contains $p) { Write-Ok $p; continue }
    $correo = Get-Correo $p
    if ($p -like 'roles/bigquery.dataViewer*' -and $equivalentes.ContainsKey($correo)) {
        Write-Ok "$p  (equivalente: READER en el dataset con condición a esta tabla, '$($equivalentes[$correo])')"
        $cubiertosPorDataset += $correo
    } else { Write-Falla $p; $fallas++ }
}
foreach ($p in $ahoraTabla) { if ($antesTabla -notcontains $p) { Write-Aviso "$p (no estaba al inicio)" } }

Write-Host "`n== Accesos del dataset ${Dataset}" -ForegroundColor Cyan
$faltanDs = @($antesDataset | Where-Object { $ahoraDataset -notcontains $_ })
$sobranDs = @($ahoraDataset | Where-Object { $antesDataset -notcontains $_ })
# Las entradas condicionadas que reemplazan un permiso de tabla se explican arriba: no son "sobrantes".
$sobranDs = @($sobranDs | Where-Object { $linea = $_; -not ($cubiertosPorDataset | Where-Object { $linea -like "*userByEmail=$_*" -or $linea -like "*groupByEmail=$_*" }) })
if ($faltanDs.Count -eq 0 -and $sobranDs.Count -eq 0) { Write-Ok "Las $($antesDataset.Count) entradas de antes siguen iguales$(if ($cubiertosPorDataset.Count) { " (+$($cubiertosPorDataset.Count) condicionadas a la tabla, ver arriba)" })" }
$faltanDs | ForEach-Object { Write-Falla $_; $fallas++ }
$sobranDs | ForEach-Object { Write-Aviso $_ }

Write-Host ''
if ($fallas -eq 0) {
    Write-Host "La tabla ${Tabla} tiene todos los permisos que tenía al inicio." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Faltan $fallas permisos. Pásale esta salida a quien administra los permisos." -ForegroundColor Red
    exit 1
}
