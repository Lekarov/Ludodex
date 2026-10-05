$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (-not (Test-Path -LiteralPath '.\web\js\config.js')) {
    throw 'Configuration absente. Exécutez d’abord .\setup.ps1 avec vos variables Supabase.'
}
python serve_nocache.py

