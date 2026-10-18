# Tests du produit pour le flux de publication, en deux passes (BUG-076 de TSA).
#
#   -Platform offscreen : toutes les suites CTest qui n'ouvrent pas de vue 3D (plateforme Qt « offscreen »).
#   -Platform windows   : les suites qui ouvrent une vraie vue OCCT (`OccView` affichée : contexte OpenGL sur une
#                         fenêtre native). Sous « offscreen », OCCT n'obtient pas ce contexte et le programme s'arrête
#                         (0xC0000409) ; ces suites passent donc en plateforme Qt native, sur le bureau de la session.
#
# Passe native : une session sans bureau (session 0, service), une suite attendue absente, un test sauté ([SKIP]) ou un
# total incomplet de la suite complète sont des échecs ; jamais un succès silencieux. Avec -SoftwareOpenGL, le rendu
# OpenGL logiciel de Mesa (llvmpipe) est placé à côté de l'exécutable des tests le temps de la passe : un runner sans
# carte graphique n'a sinon que l'OpenGL 1.1 de Windows.
param(
    [Parameter(Mandatory = $true)] [string] $BuildDir,
    [Parameter(Mandatory = $true)] [ValidateSet('offscreen', 'windows')] [string] $Platform,
    [string] $Product = 'TSA',
    [string] $SoftwareOpenGL = '',
    [string] $Log = ''
)
$ErrorActionPreference = 'Stop'

# Suites qui affichent une OccView (tests/*.cpp de TSA) ; AllTests les contient toutes (avec meshview, demo, torsion,
# qui n'ont pas de suite CTest propre). drawing et ifc sautent leur test de vue sous « offscreen » (419, 408) : elles
# passent ici pour que ces tests soient réellement exécutés.
$view3d = @('AllTests', 'auditTests', 'displayTests', 'multidocTests', 'drawingTests', 'ifcTests')
# Suites à vue 3D plus récentes que certaines branches du produit : passe native si présentes, jamais exigées
# (une version construite sur un commit antérieur ne les a pas).
$view3dIfPresent = @('viewsTests')
$regex = '^' + $Product + '_(' + (($view3d + $view3dIfPresent) -join '|') + ')$'
$env:QT_QPA_PLATFORM = $Platform

if ($Platform -eq 'offscreen') {
    # --no-tests=error : une suite introuvable est un échec, jamais un succès silencieux.
    ctest --test-dir $BuildDir --output-on-failure --no-tests=error --timeout 1800 -E $regex
    exit $LASTEXITCODE
}

$session = (Get-Process -Id $PID).SessionId
Write-Host "Session Windows $session (interactive : $([Environment]::UserInteractive))"
if ($session -eq 0) {
    throw 'Session 0 (service Windows) : aucun bureau, les vues 3D ne peuvent pas s''ouvrir. Ces suites demandent un runner ouvert dans une session interactive.'
}

$listed = ctest --test-dir $BuildDir -N -R $regex | Select-String -Pattern ('Test +#\d+: (' + $Product + '_\w+)') |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
$missing = $view3d | Where-Object { $listed -notcontains "${Product}_$_" }
if ($missing) { throw "Suites à vue 3D absentes de CTest : $($missing -join ', ')" }

$exe = Join-Path $BuildDir "${Product}_TestSuite.exe"
$mesaFiles = @('opengl32.dll', 'libgallium_wgl.dll')
$copied = @()
if ($SoftwareOpenGL) {
    foreach ($f in $mesaFiles) {
        $target = Join-Path (Split-Path $exe) $f
        if (Test-Path $target) { throw "$target existe déjà : rendu logiciel non installé (fichier du produit ?)" }
        Copy-Item (Join-Path $SoftwareOpenGL $f) $target
        $copied += $target
    }
    $env:GALLIUM_DRIVER = 'llvmpipe'
    Write-Host "Rendu OpenGL logiciel (Mesa llvmpipe) : $($mesaFiles -join ', ') depuis $SoftwareOpenGL"
}

if (-not $Log) { $Log = Join-Path $BuildDir 'tests-vue3d.log' }
try {
    ctest --test-dir $BuildDir --no-tests=error --timeout 1800 -V -R $regex --output-log $Log
    $code = $LASTEXITCODE
}
finally {
    # Le dossier de compilation sert ensuite au paquet : rien du rendu logiciel n'y reste.
    $copied | ForEach-Object { Remove-Item $_ -Force }
}

$text = Get-Content $Log -Raw -Encoding UTF8
$problems = @()
if ($code -ne 0) { $problems += "CTest : code $code" }
# Lignes écrites par les tests (préfixe « N: » de ctest -V), pas les lignes de commande réaffichées par ctest
$skips = [regex]::Matches($text, '(?m)^(?:\d+: +)?\[SKIP\][^\r\n]*') | ForEach-Object { $_.Value }
if ($skips) { $problems += "test(s) sauté(s) en plateforme native :`n  " + (($skips | Sort-Object -Unique) -join "`n  ") }
$total = [regex]::Match($text, 'RESULTS: (\d+) / (\d+) tests passed')
if (-not $total.Success) { $problems += 'total de la suite complète introuvable' }
elseif ($total.Groups[1].Value -ne $total.Groups[2].Value) {
    $problems += "suite complète : $($total.Groups[1].Value) tests réussis sur $($total.Groups[2].Value) attendus"
}

Write-Host '----- Passe à vue 3D (plateforme Qt windows)'
[regex]::Matches($text, 'rendu : [^\r\n]*') | ForEach-Object { $_.Value } | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
if ($total.Success) { Write-Host "  suite complète : $($total.Groups[1].Value) / $($total.Groups[2].Value)" }
if ($problems) {
    $problems | ForEach-Object { Write-Host "ÉCHEC : $_" }
    exit 1
}
Write-Host '  aucun test sauté, toutes les suites à vue 3D réussies'
exit 0
