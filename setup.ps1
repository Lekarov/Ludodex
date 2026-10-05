[CmdletBinding()]
param([switch]$SkipDatabase, [switch]$SkipCatalogues)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Require-EnvironmentValue([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match 'YOUR_|CHANGE_ME') {
        throw "La variable d'environnement $Name est absente ou contient encore un placeholder."
    }
    return $value
}

function Invoke-PsqlFile([string]$DatabaseUrl, [string]$Path) {
    Write-Host "Migration: $(Split-Path $Path -Leaf)"
    & psql $DatabaseUrl -X -v ON_ERROR_STOP=1 -f $Path
    if ($LASTEXITCODE -ne 0) { throw "Échec SQL dans $Path" }
}

function Invoke-PsqlCommand([string]$DatabaseUrl, [string]$Sql) {
    & psql $DatabaseUrl -X -v ON_ERROR_STOP=1 -c $Sql
    if ($LASTEXITCODE -ne 0) { throw 'Échec de la commande SQL.' }
}

$root = $PSScriptRoot
$supabaseUrl = Require-EnvironmentValue 'SUPABASE_URL'
$publishableKey = Require-EnvironmentValue 'SUPABASE_PUBLISHABLE_KEY'
if ($supabaseUrl -notmatch '^https://[a-z0-9-]+\.supabase\.co/?$') {
    throw 'SUPABASE_URL doit ressembler à https://votre-reference.supabase.co'
}

$configTemplate = Join-Path $root 'web\js\config.example.js'
$configTarget = Join-Path $root 'web\js\config.js'
$config = [IO.File]::ReadAllText($configTemplate)
$config = $config.Replace('https://YOUR_PROJECT_REF.supabase.co', $supabaseUrl.TrimEnd('/'))
$config = $config.Replace('YOUR_SUPABASE_PUBLISHABLE_KEY', $publishableKey)
[IO.File]::WriteAllText($configTarget, $config, [Text.UTF8Encoding]::new($false))
Write-Host 'Configuration frontend créée dans web/js/config.js (fichier ignoré par Git).'

if (-not $SkipDatabase) {
    if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
        throw 'psql est requis pour installer la base. Installez PostgreSQL Client puis relancez.'
    }
    $databaseUrl = Require-EnvironmentValue 'SUPABASE_DB_URL'
    $migrationDir = Join-Path $root 'schema\sql'
    $migrations = Get-ChildItem -LiteralPath $migrationDir -File -Filter '*.sql' |
        Where-Object { $_.Name -match '^\d{3}_' } | Sort-Object Name
    if ($migrations.Count -eq 0) { throw 'Aucune migration SQL trouvée.' }
    foreach ($migration in $migrations) { Invoke-PsqlFile $databaseUrl $migration.FullName }

    if (-not $SkipCatalogues) {
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            throw 'Python 3 est requis pour préparer le catalogue complet des personnages.'
        }
        $cardCsv = (Resolve-Path (Join-Path $root 'schema\catalogue_import\card_catalogue.csv')).Path.Replace('\', '/')
        $characterSource = Join-Path $root 'schema\catalogue_import\character_catalogue.csv'
        $characterDescriptions = Join-Path $root 'schema\catalogue_import\character_catalogue_descriptions.json'
        $characterReady = Join-Path $root 'schema\catalogue_import\.character_catalogue_ready.csv'
        $gameCount = (& psql $databaseUrl -X -tA -v ON_ERROR_STOP=1 -c 'select count(*) from public.card_catalogue;').Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Impossible de compter card_catalogue.' }
        if ($gameCount -eq '0') {
            Invoke-PsqlCommand $databaseUrl "\copy public.card_catalogue (card_id,rarity,rarity_name,rarity_color,family_color,title,platform_name,year,developer,image_url,atk,def,genres) from '$cardCsv' with (format csv, header true, encoding 'UTF8')"
        } elseif ($gameCount -ne '195919') {
            throw "card_catalogue contient déjà $gameCount lignes au lieu de 195919. Aucun écrasement automatique."
        } else { Write-Host 'Catalogue de jeux déjà complet, import ignoré.' }

        $characterCount = (& psql $databaseUrl -X -tA -v ON_ERROR_STOP=1 -c 'select count(*) from public.character_catalogue;').Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Impossible de compter character_catalogue.' }
        if ($characterCount -eq '0') {
            try {
                & python (Join-Path $root 'tools\merge_character_descriptions.py') $characterSource $characterDescriptions $characterReady
                if ($LASTEXITCODE -ne 0) { throw 'Impossible de construire le catalogue enrichi.' }
                $characterCsv = (Resolve-Path $characterReady).Path.Replace('\', '/')
                Invoke-PsqlCommand $databaseUrl "\copy public.character_catalogue (character_id,franchise,character_type,name,species,personality,gender,birthday,quote,games,rarity,rarity_name,rarity_color,family_color,image_url,atk,def,description_fr) from '$characterCsv' with (format csv, header true, encoding 'UTF8')"
            } finally {
                Remove-Item -LiteralPath $characterReady -Force -ErrorAction SilentlyContinue
            }
        } elseif ($characterCount -ne '48668') {
            throw "character_catalogue contient déjà $characterCount lignes au lieu de 48668. Aucun écrasement automatique."
        } else { Write-Host 'Catalogue de personnages déjà complet, import ignoré.' }
    }
}

Write-Host ''
Write-Host 'Installation terminée. Lancez ensuite: .\start.ps1'
