#!/usr/bin/env bash
#
# deploy-sql-express.sh — Install SQL Server 2022 Express on the VM.
#
# This script runs a PowerShell script on the VM via az vm run-command
# to download and silently install SQL Server Express with TCP enabled.
#
# Usage:
#   bash scripts/deploy-sql-express.sh
# ────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${RESOURCE_GROUP:=rg-contoso-sqlobs}"
: "${VM_NAME:=vm-sql-sea-01}"

echo "============================================================"
echo " Contoso SQL Observability — Deploy SQL Server Express"
echo "============================================================"
echo ""
echo " Target VM: $VM_NAME"
echo " This may take 10–15 minutes."
echo ""

echo "[1/3] Installing SQL Server 2022 Express..."

az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
    $ErrorActionPreference = "Stop"

    # Check if already installed
    $svc = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Output "SQL Server Express is already installed (Status: $($svc.Status))."
        Write-Output "Skipping installation."
        exit 0
    }

    # Step 1: Download the bootstrapper (SSEI)
    Write-Output "Downloading SQL Server 2022 Express bootstrapper..."
    $sseiPath = "C:\SQL2022-SSEI-Expr.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/p/?linkid=2216019&clcid=0x409&culture=en-us&country=us" -OutFile $sseiPath -UseBasicParsing

    # Step 2: Use SSEI to download the full media
    Write-Output "Downloading full SQL Server Express media (this may take a few minutes)..."
    $mediaPath = "C:\SQLMedia"
    $dlProcess = Start-Process -FilePath $sseiPath -ArgumentList "/Action=Download", "/MediaPath=$mediaPath", "/MediaType=Core", "/Quiet" -Wait -PassThru
    if ($dlProcess.ExitCode -ne 0) {
        Write-Error "Media download failed with exit code $($dlProcess.ExitCode)"
        exit 1
    }
    Write-Output "Media downloaded to $mediaPath"

    # Step 3: Run the downloaded installer (self-extracting exe)
    $setupExe = "C:\SQLMedia\SQLEXPR_x64_ENU.exe"
    if (-not (Test-Path $setupExe)) {
        # Fallback: search for any setup exe
        $found = Get-ChildItem -Path $mediaPath -Filter "*.exe" | Select-Object -First 1
        if (-not $found) {
            Write-Error "No installer found under $mediaPath"
            exit 1
        }
        $setupExe = $found.FullName
    }
    Write-Output "Running silent installation from $setupExe..."
    $process = Start-Process -FilePath $setupExe -ArgumentList @(
        "/Q",
        "/IACCEPTSQLSERVERLICENSETERMS",
        "/ACTION=Install",
        "/FEATURES=SQLEngine",
        "/INSTANCENAME=SQLEXPRESS",
        "/SECURITYMODE=SQL",
        "/SAPWD=Contoso!Sql2024",
        "/TCPENABLED=1",
        "/UPDATEENABLED=0"
    ) -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Error "SQL Server installation failed with exit code $($process.ExitCode)"
        exit 1
    }

    Write-Output "SQL Server Express installed successfully."
  '

echo "  ✓ SQL Server Express installation complete"

echo ""
echo "[2/3] Configuring SQL Server for TCP/IP and event logging..."

az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
    $ErrorActionPreference = "Stop"

    # Ensure SQL Server service is running
    $svc = Get-Service -Name "MSSQL`$SQLEXPRESS"
    if ($svc.Status -ne "Running") {
        Start-Service -Name "MSSQL`$SQLEXPRESS"
        Write-Output "Started SQL Server Express service."
    }

    # Enable SQL Server Browser (needed for named instance discovery)
    $browser = Get-Service -Name "SQLBrowser" -ErrorAction SilentlyContinue
    if ($browser) {
        Set-Service -Name "SQLBrowser" -StartupType Automatic
        Start-Service -Name "SQLBrowser" -ErrorAction SilentlyContinue
        Write-Output "SQL Browser service enabled and started."
    }

    # Configure Windows Firewall for SQL Server
    $ruleName = "SQL Server Express (TCP 1433)"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $ruleName `
            -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
        Write-Output "Firewall rule created for TCP 1433."
    }

    # Enable SQL error logging to Windows Event Log (already default, verify)
    Write-Output "SQL Server configuration complete."
    Write-Output "Service status: $((Get-Service -Name ''MSSQL`$SQLEXPRESS'').Status)"
  '

echo "  ✓ SQL Server configured"

echo ""
echo "[3/3] Verifying installation..."

az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
    Write-Output "=== SQL Server Services ==="
    Get-Service -Name "*SQL*" | Format-Table Name, Status, StartType -AutoSize

    Write-Output "`n=== SQL Server Version ==="
    try {
        $instance = "localhost\SQLEXPRESS"
        $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$instance;Integrated Security=True;TrustServerCertificate=True")
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT @@VERSION AS Version"
        $reader = $cmd.ExecuteReader()
        $reader.Read() | Out-Null
        Write-Output $reader["Version"]
        $conn.Close()
    } catch {
        Write-Output "Could not query version: $_"
    }
  '

echo ""
echo "============================================================"
echo " SQL Server Express deployment complete"
echo ""
echo " Instance name:  $VM_NAME\SQLEXPRESS"
echo " SA Password:    Contoso!Sql2024"
echo " TCP Port:       1433"
echo ""
echo " Run 'bash scripts/check-vm-sql.sh' to verify health."
echo "============================================================"
