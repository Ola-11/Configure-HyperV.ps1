# Configure-HyperV.ps1

# 1. Install Hyper-V and Management Tools
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart

# Wait for reboot and resume script (if needed)
Start-Sleep -Seconds 30

# 2. Create an Internal Hyper-V Virtual Switch
New-VMSwitch -Name "InternalSwitch" -SwitchType Internal

# 3. Download Ubuntu Cloud Image (20.04 LTS)
$ubuntuImageUrl = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.vhd"
$downloadPath = "C:\HyperV\Images\ubuntu-20.04.vhd"
New-Item -Path "C:\HyperV\Images" -ItemType Directory -Force
Invoke-WebRequest -Uri $ubuntuImageUrl -OutFile $downloadPath

# 4. Create Nested VMs
function Create-NestedVM {
  param (
    [string]$VMName,
    [string]$VMPath,
    [string]$VHDXPath,
    [int]$MemoryGB,
    [int]$ProcessorCount,
    [string]$CloudInitConfig
  )

  # Create VM and VHDX
  New-VM -Name $VMName -Path $VMPath -MemoryStartupBytes ($MemoryGB * 1GB) -SwitchName InternalSwitch -Generation 2
  New-VHD -Path $VHDXPath -SizeBytes 20GB -Dynamic
  Add-VMHardDiskDrive -VMName $VMName -Path $VHDXPath

  # Configure Processor and Network
  Set-VMProcessor -VMName $VMName -Count $ProcessorCount
  Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress (New-VMNetworkAdapter | Select-Object -ExpandProperty MacAddress)

  # Attach Ubuntu Image and Cloud-Init Config
  Set-VMDvdDrive -VMName $VMName -Path $downloadPath
  Set-VM -VMName $VMName -ProcessorCount $ProcessorCount

  # Inject Cloud-Init Configuration
  New-Item -Path "$VMPath\$VMName\cloud-init" -ItemType Directory -Force
  Set-Content -Path "$VMPath\$VMName\cloud-init\user-data" -Value $CloudInitConfig
  Set-Content -Path "$VMPath\$VMName\cloud-init\meta-data" -Value "instance-id: $VMName"

  # Start VM
  Start-VM -Name $VMName
}

# Cloud-Init Configuration for WAF (NGINX + ModSecurity)
$wafCloudInit = @"
#cloud-config
users:
  - name: azureuser
    ssh-authorized-keys:
      - $(Get-Content -Path $env:UserProfile\.ssh\id_rsa.pub)
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

# Cloud-Init Configuration for Web Servers (Apache + PHP)
$webCloudInit = @"
#cloud-config
users:
  - name: azureuser
    ssh-authorized-keys:
      - $(Get-Content -Path $env:UserProfile\.ssh\id_rsa.pub)
packages:
  - apache2
  - php
runcmd:
  - echo '<html><body><h1>Web Server Ready</h1></body></html>' > /var/www/html/index.html
  - systemctl enable apache2
  - systemctl start apache2
"@

# Cloud-Init Configuration for SQL Server
$sqlCloudInit = @"
#cloud-config
users:
  - name: azureuser
    ssh-authorized-keys:
      - $(Get-Content -Path $env:UserProfile\.ssh\id_rsa.pub)
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

# Create Nested VMs
Create-NestedVM -VMName "WAF" -VMPath "C:\HyperV\VMs" -VHDXPath "C:\HyperV\VHDs\WAF.vhdx" -MemoryGB 4 -ProcessorCount 2 -CloudInitConfig $wafCloudInit
Create-NestedVM -VMName "Web1" -VMPath "C:\HyperV\VMs" -VHDXPath "C:\HyperV\VHDs\Web1.vhdx" -MemoryGB 2 -ProcessorCount 2 -CloudInitConfig $webCloudInit
Create-NestedVM -VMName "Web2" -VMPath "C:\HyperV\VMs" -VHDXPath "C:\HyperV\VHDs\Web2.vhdx" -MemoryGB 2 -ProcessorCount 2 -CloudInitConfig $webCloudInit
Create-NestedVM -VMName "SQL" -VMPath "C:\HyperV\VMs" -VHDXPath "C:\HyperV\VHDs\SQL.vhdx" -MemoryGB 8 -ProcessorCount 4 -CloudInitConfig $sqlCloudInit

# 5. Open Firewall Ports (Optional)
New-NetFirewallRule -DisplayName "Allow HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow
New-NetFirewallRule -DisplayName "Allow SQL" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
