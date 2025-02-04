# Configure-HyperV.ps1

# 1. Check if Hyper-V is installed
if (!(Get-WindowsFeature -Name Hyper-V).Installed) {
    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
    Write-Host "Hyper-V installation complete. Restarting..."
    shutdown /r /t 30
    exit
} else {
    Write-Host "Hyper-V is already installed. Skipping installation."
}

# 2. Create an Internal Hyper-V Virtual Switch
if (!(Get-VMSwitch -Name "InternalSwitch" -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name "InternalSwitch" -SwitchType Internal
    Write-Host "Internal Hyper-V Virtual Switch created."
} else {
    Write-Host "InternalSwitch already exists. Skipping creation."
}

# 3. Download Ubuntu Cloud Image (20.04 LTS)
$ubuntuImageUrl = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.vhd"
$downloadPath = "C:\HyperV\Images\ubuntu-20.04.vhd"

if (!(Test-Path "C:\HyperV\Images")) {
    New-Item -Path "C:\HyperV\Images" -ItemType Directory -Force
}

try {
    if (!(Test-Path $downloadPath)) {
        Invoke-WebRequest -Uri $ubuntuImageUrl -OutFile $downloadPath -ErrorAction Stop
        Write-Host "Ubuntu image downloaded successfully."
    } else {
        Write-Host "Ubuntu image already exists. Skipping download."
    }
} catch {
    Write-Host "Error downloading Ubuntu image: $_"
    exit 1
}

# 4. Function to Create Nested VMs
function Create-NestedVM {
  param (
    [string]$VMName,
    [string]$VMPath,
    [string]$VHDXPath,
    [int]$MemoryGB,
    [int]$ProcessorCount,
    [string]$CloudInitConfig
  )

  if (!(Test-Path $VMPath)) {
    New-Item -Path $VMPath -ItemType Directory -Force
  }

  if (!(Test-Path $VHDXPath)) {
    New-VHD -Path $VHDXPath -SizeBytes 20GB -Dynamic
  }

  if (!(Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    New-VM -Name $VMName -Path $VMPath -MemoryStartupBytes ($MemoryGB * 1GB) -SwitchName InternalSwitch -Generation 2
    Set-VM -VMName $VMName -ProcessorCount $ProcessorCount
    Add-VMHardDiskDrive -VMName $VMName -Path $VHDXPath
    Add-VMHardDiskDrive -VMName $VMName -Path $downloadPath  # Attach Ubuntu VHD
    Write-Host "VM $VMName created successfully."
  } else {
    Write-Host "VM $VMName already exists. Skipping creation."
  }

  # Inject Cloud-Init Configuration
  $cloudInitPath = "$VMPath\$VMName\cloud-init"
  if (!(Test-Path $cloudInitPath)) {
    New-Item -Path $cloudInitPath -ItemType Directory -Force
  }
  Set-Content -Path "$cloudInitPath\user-data" -Value $CloudInitConfig
  Set-Content -Path "$cloudInitPath\meta-data" -Value "instance-id: $VMName"

  # Start VM
  Start-VM -Name $VMName
}

# 5. Retrieve SSH Key (Fix Path Issue)
$sshKeyPath = "$env:UserProfile\.ssh\id_rsa.pub"
if (Test-Path $sshKeyPath) {
    $sshKey = Get-Content -Path $sshKeyPath -Raw
} else {
    Write-Host "Warning: SSH Key not found at $sshKeyPath. Ensure you have generated an SSH key."
    $sshKey = ""
}

# 6. Cloud-Init Configurations
$wafCloudInit = @"
#cloud-config
users:
  - name: azureuser
    ssh-authorized-keys:
      - $sshKey
packages:
  - nginx
  - libmodsecurity3
  - modsecurity-crs
write_files:
  - path: /etc/nginx/modsecurity/modsecurity.conf
    content: |
      SecRuleEngine On
      SecAuditLog /var/log/nginx/modsec_audit.log
runcmd:
  - systemctl enable nginx
  - systemctl start nginx
"@

$webCloudInit = @"
#cloud-config
users:
  - name: azureuser
    ssh-authorized-keys:
      - $sshKey
packages:
  - apache2
  - php
runcmd:
  - echo '<html><body><h1>Web Server Ready</h1></body></html>' > /var/www/html/index.html
  - systemctl enable apache2
  - systemctl start apache2
"@

$sqlCloudInit = @"
#cloud-config
users:
  - name: azureuser
    ssh-authorized-keys:
      - $sshKey
packages:
  - curl
runcmd:
  - curl -o /tmp/mssql-install.sh https://packages.microsoft.com/config/ubuntu/20.04/mssql-server-2019.list
  - sudo bash /tmp/mssql-install.sh
  - sudo apt-get update
  - sudo apt-get install -y mssql-server
  - sudo /opt/mssql/bin/mssql-conf setup accept-eula
  - systemctl enable mssql-server
  - systemctl start mssql-server
"@

# 7. Create Nested VMs
Create-NestedVM -VMName "WAF" -VMPath "C:\HyperV\VMs" -VHDXPath "C:\HyperV\VHDs\WAF.vhdx" -MemoryGB 4 -ProcessorCount 2 -CloudInitConfig $wafCloudInit
Create-NestedVM -VMName "Web1" -VMPath "C:\HyperV\VMs" -VHDXPath "C:\HyperV\VHDs\Web1.vhdx" -MemoryGB 2 -ProcessorCount 2 -CloudInitConfig $webCloudInit
Create-NestedVM -VMName "Web2" -VMPath "C:\HyperV\VMs" -VHDXPath "C:\HyperV\VHDs\Web2.vhdx" -MemoryGB 2 -ProcessorCount 2 -CloudInitConfig $webCloudInit
Create-NestedVM -VMName "SQL" -VMPath "C:\HyperV\VMs" -VHDXPath "C:\HyperV\VHDs\SQL.vhdx" -MemoryGB 8 -ProcessorCount 4 -CloudInitConfig $sqlCloudInit

# 8. Open Firewall Ports (Optional)
New-NetFirewallRule -DisplayName "Allow HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow
New-NetFirewallRule -DisplayName "Allow SQL" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
