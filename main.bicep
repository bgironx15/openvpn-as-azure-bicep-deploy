// OpenVPN Access Server on Ubuntu 26.04 LTS (Azure)
// Deploys: NSG, VNet/subnet, static Standard public IP with DNS label, NIC, VM.
// cloud-init installs AS, sets host.name to the public IP, and requests a Let's Encrypt
// short-lived IP certificate through the AS ACME client.

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Prefix used for resource names.')
param namePrefix string = 'openvpn-as'

@description('VM size. Standard_D2pls_v6 is Arm64 (Azure Cobalt 100), so the image must be an Arm64 image.')
param vmSize string = 'Standard_D2pls_v6'

@description('Linux hostname of the VM (the OS name, not the Azure resource name).')
@maxLength(64)
param hostname string = 'openvpnas3'

@description('Admin username for SSH.')
param adminUsername string = 'azureuser'

@description('SSH public key (contents of ~/.ssh/id_ed25519.pub or id_rsa.pub).')
@secure()
param sshPublicKey string

@description('Your public IP as a /32 (e.g. 203.0.113.10/32). Not used by default; swap it into the SSH (22) and Web UI (943) rules to restrict them (recommended).')
#disable-next-line no-unused-params
param adminSourceCidr string = ''

@description('Globally unique DNS label for the public IP (lowercase, letters/digits/hyphens).')
param dnsLabel string = toLower('${namePrefix}-${uniqueString(resourceGroup().id)}')

@description('Access Server version passed to the install script.')
param asVersion string = '3.2.4'

@description('Password for the openvpn admin user (required). Passed to Access Server as admin_pw in the VM user data.')
@secure()
@minLength(1)
param admin_password string

@description('Ubuntu Arm64 image reference. Verify with: az vm image list --publisher Canonical --offer ubuntu-26_04 --architecture Arm64 --all -o table')
param imageReference object = {
  publisher: 'Canonical'
  offer: 'ubuntu-26_04-lts'
  sku: 'server-arm64'
  version: 'latest'
}

var vnetName = '${namePrefix}-vnet'
var subnetName = 'default'
var nsgName = '${namePrefix}-nsg'
var pipName = '${namePrefix}-pip'
var nicName = '${namePrefix}-nic'
var vmName = '${namePrefix}-vm'

// {0} = AS version, {1} = VM public IP (used for host.name and the Let's Encrypt IP certificate)
// The openvpn password is not handled here: it goes in the VM user data (see the vm resource),
// which ovpn-init reads as admin_pw=<password>.
// Everything runs from one script so it executes in order and logs to /var/log/as-setup.log.
var cloudInit = format('''#cloud-config
package_update: true
packages:
  - curl
write_files:
  - path: /usr/local/sbin/as-setup.sh
    permissions: '0700'
    content: |
      #!/bin/bash
      touch /var/log/as-setup.log && chmod 600 /var/log/as-setup.log
      exec > >(tee -a /var/log/as-setup.log) 2>&1
      bash <(curl -fsS https://packages.openvpn.net/as/install.sh) --as-version={0} --yes
      export PATH="$PATH:/usr/local/openvpn_as/bin:/usr/local/openvpn_as/scripts"
      ovpn-init --azure --batch --force
      apt-mark hold openvpn-as
      . /usr/local/openvpn_as/etc/VERSION
      echo "OpenVPN Access Server Appliance $AS_VERSION \n \l" > /etc/issue
      cat > /etc/update-motd.d/00-header <<HEADER
      #!/bin/sh
      echo "Welcome to OpenVPN Access Server Appliance $AS_VERSION"
      HEADER
      chmod 755 /etc/update-motd.d/00-header
      until sacli status 2>/dev/null | grep -q '"api": "on"'; do sleep 2; done
      sacli --key "host.name" --value "{1}" ConfigPut
      sacli --key "acme.ip_addresses.0" --value "{1}" ConfigPut
      sacli --key "acme.cert_profile" --value "shortlived" ConfigPut
      sacli start
      until sacli status 2>/dev/null | grep -q '"api": "on"'; do sleep 2; done
      echo y | sacli AcmeRegisterAccount
      sacli AcmeRequestCertificate
      exit 0
runcmd:
  - [ /usr/local/sbin/as-setup.sh ]
''', asVersion, pip.properties.ipAddress)

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          // WARNING: SSH is open to the entire internet. This is NOT recommended.
          // Restrict it to your own public IP instead by replacing '*' with adminSourceCidr
          // (set adminSourceCidr to your public IP as a /32, e.g. 203.0.113.10/32).
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-AS-WebUI-943'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          // WARNING: The Admin/Client Web UI is open to the entire internet. This is NOT recommended.
          // Restrict it to your own public IP instead by replacing '*' with adminSourceCidr
          // (set adminSourceCidr to your public IP as a /32, e.g. 203.0.113.10/32).
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '943'
        }
      }
      {
        name: 'Allow-AS-TCP-443'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-AS-UDP-1194'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '1194'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.10.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: nicName
  location: location
  properties: {
    // Needed only if you switch AS from NAT to routing mode; harmless otherwise.
    enableIPForwarding: true
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: vmName
  location: location
  properties: {
    // Access Server reads admin_pw from the VM user data during ovpn-init.
    userData: base64('admin_pw=${admin_password}')
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: hostname
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 30
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output publicIp string = pip.properties.ipAddress
output adminWebUi string = 'https://${pip.properties.ipAddress}:943/admin'
output clientWebUi string = 'https://${pip.properties.ipAddress}/'
output sshCommand string = 'ssh ${adminUsername}@${pip.properties.ipAddress}'

// The password is shown here in plain text and is kept in the deployment history,
// readable by anyone with Reader access to the resource group.
#disable-next-line outputs-should-not-contain-secrets
output adminPassword string = admin_password
