# =====================================================================
#  Deterministic backend assertion against Dataverse.
#
#  An LLM judge scores a conversation. This scores the database.
#  "The agent was polite" is debatable. "The record exists" is not.
#
#  Auth: service principal when DV_CLIENT_ID / DV_CLIENT_SECRET /
#  DV_TENANT_ID are set, interactive device code otherwise. The OData
#  call is identical either way.
#
#  Usage:
#    .\scripts\assert-dataverse.ps1 -EntitySet accounts -Top 3
#    .\scripts\assert-dataverse.ps1 -EntitySet aqa_refundrequests `
#        -Filter "aqa_ordernumber eq '12345ABCDE'" -ExpectAtLeast 1
#    .\scripts\assert-dataverse.ps1 -EntitySet aqa_refundrequests `
#        -Select "aqa_name,aqa_ordernumber" -OrderBy "createdon desc" -Top 8
# =====================================================================

param(
    [string] $OrgUrl        = "https://org93bc4cbc.crm17.dynamics.com",
    [string] $EntitySet     = "accounts",
    [string] $Filter,
    [string] $Select,
    [string] $OrderBy,
    [int]    $Top           = 5,
    [int]    $ExpectAtLeast = 0
)

$ErrorActionPreference = "Stop"
$OrgUrl = $OrgUrl.TrimEnd('/')

# --- 1. Token -------------------------------------------------------
if ($env:DV_CLIENT_ID -and $env:DV_CLIENT_SECRET -and $env:DV_TENANT_ID) {
    Write-Host "Auth: service principal" -ForegroundColor DarkGray
    $token = (Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$($env:DV_TENANT_ID)/oauth2/v2.0/token" `
        -Body @{
            grant_type    = "client_credentials"
            client_id     = $env:DV_CLIENT_ID
            client_secret = $env:DV_CLIENT_SECRET
            scope         = "$OrgUrl/.default"
        }).access_token
}
else {
    Write-Host "Auth: interactive (no service principal configured)" -ForegroundColor DarkGray
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host "Installing Az.Accounts..." -ForegroundColor DarkGray
        Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Az.Accounts
    if (-not (Get-AzContext)) {
        # Connect-AzAccount throws when the tenant has no Azure subscription,
        # even though sign-in succeeded and the token is usable. Device code
        # is not an option: it cannot carry device-compliance claims.
        try { Connect-AzAccount -ErrorAction Stop | Out-Null } catch { }

        if (-not (Get-AzContext)) {
            Write-Host "Sign-in did not produce a usable context." -ForegroundColor Red
            Write-Host "Fallback: open the OData URL directly in your browser." -ForegroundColor Yellow
            Write-Host "$OrgUrl/api/data/v9.2/$EntitySet`?`$top=$Top" -ForegroundColor Yellow
            exit 1
        }
    }

    $raw = (Get-AzAccessToken -ResourceUrl $OrgUrl).Token
    # Recent Az versions return a SecureString.
    $token = if ($raw -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new("", $raw).Password
    } else { $raw }
}

# --- 2. Query -------------------------------------------------------
$query = @("`$top=$Top")
if ($Select)  { $query += "`$select=$Select" }
if ($Filter)  { $query += "`$filter=$Filter" }
if ($OrderBy) { $query += "`$orderby=$OrderBy" }
$uri = "$OrgUrl/api/data/v9.2/$EntitySet" + "?" + ($query -join "&")

Write-Host "GET $uri" -ForegroundColor DarkGray

$r = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
    Authorization    = "Bearer $token"
    Accept           = "application/json"
    "OData-Version"  = "4.0"
    "OData-MaxVersion" = "4.0"
}

# --- 3. Verdict -----------------------------------------------------
$count = @($r.value).Count
Write-Host ""
# Dataverse returns @odata.etag and the primary key even with $select.
if ($Select) {
    $r.value | Format-Table -AutoSize -Property ($Select -split '\s*,\s*')
} else {
    $r.value | Format-Table -AutoSize
}

if ($count -ge $ExpectAtLeast -and $ExpectAtLeast -gt 0) {
    Write-Host "ASSERTION PASSED - $count matching record(s) in Dataverse" -ForegroundColor Green
    exit 0
}
elseif ($ExpectAtLeast -gt 0) {
    Write-Host "ASSERTION FAILED - expected at least $ExpectAtLeast, found $count" -ForegroundColor Red
    Write-Host "The agent may have claimed success without writing anything." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "Dataverse OK - $count row(s) read" -ForegroundColor Green
    exit 0
}
