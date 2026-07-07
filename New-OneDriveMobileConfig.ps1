<#
.SYNOPSIS
    OneDrive macOS .mobileconfig Generator (offline, GUI)

.DESCRIPTION
    WinForms tool that generates Intune-importable .mobileconfig profiles for the
    macOS OneDrive sync client (preference domain: com.microsoft.OneDrive).

    Generates, per customer:
      - AllowTenantList profile   (restrict sync to specific Entra tenant IDs)
      - DisablePersonalSync profile (block personal Microsoft accounts)
    as two separate files, or a single combined profile.

    Fully offline - no modules, no internet. Requires Windows PowerShell 5.1+ or
    PowerShell 7 on Windows.

.NOTES
    Author  : Hulsman Systems
    Usage   : Right-click > Run with PowerShell, or:
              powershell.exe -ExecutionPolicy Bypass -File .\New-OneDriveMobileConfig.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

#region Helper functions ------------------------------------------------------

function ConvertTo-XmlSafe {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [System.Security.SecurityElement]::Escape($Text)
}

function New-ReverseDns {
    param([string]$CustomerName)
    # "Flowerbed Engineering B.V." -> "flowerbedengineeringbv"
    $clean = ($CustomerName -replace '[^a-zA-Z0-9]', '').ToLower()
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'customer' }
    return "nl.$clean"
}

function Test-Guid {
    param([string]$Value)
    $g = [guid]::Empty
    return [guid]::TryParse($Value.Trim(), [ref]$g)
}

function New-MobileConfig {
    <#
        Builds one complete .mobileconfig XML string.
        SettingsXml = inner plist keys for the com.microsoft.OneDrive payload.
    #>
    param(
        [string]$Organization,
        [string]$IdentifierBase,     # e.g. nl.knmt.onedrive.allowtenantlist
        [string]$DisplayName,
        [string]$Description,
        [string]$SettingsXml,
        [bool]$RemovalDisallowed
    )

    $orgEsc  = ConvertTo-XmlSafe $Organization
    $nameEsc = ConvertTo-XmlSafe $DisplayName
    $descEsc = ConvertTo-XmlSafe $Description
    $uuidRoot    = [guid]::NewGuid().ToString().ToUpper()
    $uuidPayload = [guid]::NewGuid().ToString().ToUpper()
    $removal = if ($RemovalDisallowed) { '<true/>' } else { '<false/>' }

    return @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.microsoft.OneDrive</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>$IdentifierBase.payload</string>
            <key>PayloadUUID</key>
            <string>$uuidPayload</string>
            <key>PayloadDisplayName</key>
            <string>$nameEsc</string>
            <key>PayloadDescription</key>
            <string>$descEsc</string>
            <key>PayloadOrganization</key>
            <string>$orgEsc</string>
$SettingsXml
        </dict>
    </array>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadIdentifier</key>
    <string>$IdentifierBase</string>
    <key>PayloadUUID</key>
    <string>$uuidRoot</string>
    <key>PayloadDisplayName</key>
    <string>$nameEsc</string>
    <key>PayloadDescription</key>
    <string>$descEsc</string>
    <key>PayloadOrganization</key>
    <string>$orgEsc</string>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadRemovalDisallowed</key>
    $removal
</dict>
</plist>
"@
}

function Get-TenantListXml {
    param([string[]]$TenantIds)
    $entries = ($TenantIds | ForEach-Object { "                <string>$($_.Trim().ToLower())</string>" }) -join "`r`n"
    return @"
            <key>AllowTenantList</key>
            <array>
$entries
            </array>
"@
}

$DisablePersonalSyncXml = @"
            <key>DisablePersonalSync</key>
            <true/>
"@

#endregion

#region GUI -------------------------------------------------------------------

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'OneDrive macOS .mobileconfig Generator'
$form.Size            = New-Object System.Drawing.Size(620, 640)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$y = 15

# --- Customer name
$lblCustomer = New-Object System.Windows.Forms.Label
$lblCustomer.Text = 'Customer / organization name:'
$lblCustomer.Location = New-Object System.Drawing.Point(15, $y)
$lblCustomer.AutoSize = $true
$form.Controls.Add($lblCustomer)

$txtCustomer = New-Object System.Windows.Forms.TextBox
$txtCustomer.Location = New-Object System.Drawing.Point(230, ($y - 3))
$txtCustomer.Size = New-Object System.Drawing.Size(355, 23)
$form.Controls.Add($txtCustomer)
$y += 35

# --- Identifier prefix (reverse DNS)
$lblPrefix = New-Object System.Windows.Forms.Label
$lblPrefix.Text = 'Identifier prefix (reverse DNS):'
$lblPrefix.Location = New-Object System.Drawing.Point(15, $y)
$lblPrefix.AutoSize = $true
$form.Controls.Add($lblPrefix)

$txtPrefix = New-Object System.Windows.Forms.TextBox
$txtPrefix.Location = New-Object System.Drawing.Point(230, ($y - 3))
$txtPrefix.Size = New-Object System.Drawing.Size(355, 23)
$form.Controls.Add($txtPrefix)
$y += 35

# Auto-suggest prefix from customer name (only while user hasn't customized it)
$script:PrefixTouched = $false
$txtPrefix.Add_KeyDown({ $script:PrefixTouched = $true })
$txtCustomer.Add_TextChanged({
    if (-not $script:PrefixTouched) {
        $txtPrefix.Text = New-ReverseDns $txtCustomer.Text
    }
})

# --- Profiles group
$grpProfiles = New-Object System.Windows.Forms.GroupBox
$grpProfiles.Text = 'Profiles to generate'
$grpProfiles.Location = New-Object System.Drawing.Point(15, $y)
$grpProfiles.Size = New-Object System.Drawing.Size(570, 105)
$form.Controls.Add($grpProfiles)

$chkTenant = New-Object System.Windows.Forms.CheckBox
$chkTenant.Text = 'AllowTenantList  (restrict sync client to specific Entra tenant IDs)'
$chkTenant.Location = New-Object System.Drawing.Point(15, 25)
$chkTenant.Size = New-Object System.Drawing.Size(540, 22)
$chkTenant.Checked = $true
$grpProfiles.Controls.Add($chkTenant)

$chkPersonal = New-Object System.Windows.Forms.CheckBox
$chkPersonal.Text = 'DisablePersonalSync  (block personal Microsoft accounts)'
$chkPersonal.Location = New-Object System.Drawing.Point(15, 50)
$chkPersonal.Size = New-Object System.Drawing.Size(540, 22)
$chkPersonal.Checked = $true
$grpProfiles.Controls.Add($chkPersonal)

$chkCombined = New-Object System.Windows.Forms.CheckBox
$chkCombined.Text = 'Combine selected settings into one .mobileconfig (default: separate files)'
$chkCombined.Location = New-Object System.Drawing.Point(15, 75)
$chkCombined.Size = New-Object System.Drawing.Size(540, 22)
$grpProfiles.Controls.Add($chkCombined)

$y += 120

# --- Tenant IDs
$lblTenants = New-Object System.Windows.Forms.Label
$lblTenants.Text = 'Allowed Entra tenant ID(s) - one GUID per line:'
$lblTenants.Location = New-Object System.Drawing.Point(15, $y)
$lblTenants.AutoSize = $true
$form.Controls.Add($lblTenants)
$y += 22

$txtTenants = New-Object System.Windows.Forms.TextBox
$txtTenants.Multiline = $true
$txtTenants.ScrollBars = 'Vertical'
$txtTenants.Location = New-Object System.Drawing.Point(15, $y)
$txtTenants.Size = New-Object System.Drawing.Size(570, 80)
$txtTenants.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtTenants)
$y += 95

$chkTenant.Add_CheckedChanged({
    $txtTenants.Enabled = $chkTenant.Checked
    $lblTenants.Enabled = $chkTenant.Checked
})

# --- Options
$chkRemoval = New-Object System.Windows.Forms.CheckBox
$chkRemoval.Text = 'PayloadRemovalDisallowed (prevent manual removal of the profile)'
$chkRemoval.Location = New-Object System.Drawing.Point(15, $y)
$chkRemoval.Size = New-Object System.Drawing.Size(570, 22)
$chkRemoval.Checked = $true
$form.Controls.Add($chkRemoval)
$y += 35

# --- Output folder
$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text = 'Output folder:'
$lblOut.Location = New-Object System.Drawing.Point(15, $y)
$lblOut.AutoSize = $true
$form.Controls.Add($lblOut)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(120, ($y - 3))
$txtOut.Size = New-Object System.Drawing.Size(375, 23)
$txtOut.Text = [Environment]::GetFolderPath('Desktop')
$form.Controls.Add($txtOut)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(505, ($y - 4))
$btnBrowse.Size = New-Object System.Drawing.Size(80, 25)
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $txtOut.Text
    if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.SelectedPath }
})
$form.Controls.Add($btnBrowse)
$y += 40

# --- Generate button
$btnGenerate = New-Object System.Windows.Forms.Button
$btnGenerate.Text = 'Generate .mobileconfig'
$btnGenerate.Location = New-Object System.Drawing.Point(15, $y)
$btnGenerate.Size = New-Object System.Drawing.Size(570, 35)
$btnGenerate.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnGenerate.ForeColor = [System.Drawing.Color]::White
$btnGenerate.FlatStyle = 'Flat'
$form.Controls.Add($btnGenerate)
$y += 45

# --- Status box
$txtStatus = New-Object System.Windows.Forms.TextBox
$txtStatus.Multiline = $true
$txtStatus.ScrollBars = 'Vertical'
$txtStatus.ReadOnly = $true
$txtStatus.Location = New-Object System.Drawing.Point(15, $y)
$txtStatus.Size = New-Object System.Drawing.Size(570, 110)
$txtStatus.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$txtStatus.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($txtStatus)

function Write-Status {
    param([string]$Message)
    $txtStatus.AppendText("[$([DateTime]::Now.ToString('HH:mm:ss'))] $Message`r`n")
}

#endregion

#region Generate logic --------------------------------------------------------

$btnGenerate.Add_Click({
    $txtStatus.Clear()

    # --- Validation
    $customer = $txtCustomer.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($customer)) {
        Write-Status 'ERROR: Customer name is required.'
        return
    }

    $prefix = $txtPrefix.Text.Trim().TrimEnd('.')
    if ($prefix -notmatch '^[a-zA-Z0-9]+(\.[a-zA-Z0-9-]+)+$') {
        Write-Status "ERROR: Identifier prefix must be reverse-DNS format, e.g. nl.customername"
        return
    }
    $prefix = $prefix.ToLower()

    if (-not $chkTenant.Checked -and -not $chkPersonal.Checked) {
        Write-Status 'ERROR: Select at least one profile to generate.'
        return
    }

    $tenantIds = @()
    if ($chkTenant.Checked) {
        $tenantIds = @($txtTenants.Lines | Where-Object { $_.Trim() -ne '' })
        if ($tenantIds.Count -eq 0) {
            Write-Status 'ERROR: AllowTenantList selected but no tenant ID entered.'
            return
        }
        foreach ($t in $tenantIds) {
            if (-not (Test-Guid $t)) {
                Write-Status "ERROR: '$($t.Trim())' is not a valid GUID."
                return
            }
        }
    }

    $outDir = $txtOut.Text.Trim()
    if (-not (Test-Path -LiteralPath $outDir)) {
        try {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            Write-Status "Created output folder: $outDir"
        } catch {
            Write-Status "ERROR: Cannot create output folder: $($_.Exception.Message)"
            return
        }
    }

    $removal  = $chkRemoval.Checked
    $fileSafe = ($customer -replace '[\\/:*?"<>|]', '').Trim() -replace '\s+', '-'
    $written  = @()

    try {
        # UTF-8 without BOM - Intune/Apple parsers are picky about BOMs
        $enc = New-Object System.Text.UTF8Encoding($false)

        if ($chkCombined.Checked) {
            # --- One combined profile
            $settings = @()
            if ($chkPersonal.Checked) { $settings += $DisablePersonalSyncXml }
            if ($chkTenant.Checked)   { $settings += (Get-TenantListXml $tenantIds) }

            $xml = New-MobileConfig `
                -Organization $customer `
                -IdentifierBase "$prefix.onedrive.restrictions" `
                -DisplayName "macOS - OneDrive - Account Restrictions" `
                -Description "OneDrive sync client restrictions for $customer" `
                -SettingsXml ($settings -join "`r`n") `
                -RemovalDisallowed $removal

            $path = Join-Path $outDir "OneDrive-Restrictions-$fileSafe-macOS.mobileconfig"
            [System.IO.File]::WriteAllText($path, $xml, $enc)
            $written += $path
        }
        else {
            # --- Separate profiles
            if ($chkTenant.Checked) {
                $xml = New-MobileConfig `
                    -Organization $customer `
                    -IdentifierBase "$prefix.onedrive.allowtenantlist" `
                    -DisplayName "macOS - OneDrive - Allowed Tenants Only" `
                    -Description "Restricts the OneDrive sync client to approved Entra tenant(s) for $customer" `
                    -SettingsXml (Get-TenantListXml $tenantIds) `
                    -RemovalDisallowed $removal

                $path = Join-Path $outDir "OneDrive-AllowTenantList-$fileSafe-macOS.mobileconfig"
                [System.IO.File]::WriteAllText($path, $xml, $enc)
                $written += $path
            }
            if ($chkPersonal.Checked) {
                $xml = New-MobileConfig `
                    -Organization $customer `
                    -IdentifierBase "$prefix.onedrive.disablepersonalsync" `
                    -DisplayName "macOS - OneDrive - Block Personal Accounts" `
                    -Description "Blocks personal Microsoft accounts in the OneDrive sync client for $customer" `
                    -SettingsXml $DisablePersonalSyncXml `
                    -RemovalDisallowed $removal

                $path = Join-Path $outDir "OneDrive-DisablePersonalSync-$fileSafe-macOS.mobileconfig"
                [System.IO.File]::WriteAllText($path, $xml, $enc)
                $written += $path
            }
        }

        foreach ($f in $written) { Write-Status "OK: $f" }
        Write-Status "Done. $($written.Count) file(s) generated. Import via Intune > Devices > macOS >"
        Write-Status "Configuration profiles > Create > Templates > Custom (Device channel)."
    }
    catch {
        Write-Status "ERROR: $($_.Exception.Message)"
    }
})

#endregion

[void]$form.ShowDialog()
