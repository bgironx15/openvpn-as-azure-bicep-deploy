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

@description('Password for the openvpn admin user. Leave empty to keep the auto-generated password (written to /var/log/as-setup.log).')
@secure()
param admin_pw string = ''

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
var fqdn = '${dnsLabel}.${location}.cloudapp.azure.com'

// {0} = AS version, {1} = VM public IP (used for host.name and the Let's Encrypt IP certificate),
// {2} = admin_pw, base64-encoded so any characters survive YAML and shell quoting (empty if not set)
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
      umask 077
      exec > >(tee -a /var/log/as-setup.log) 2>&1
      bash <(curl -fsS https://packages.openvpn.net/as/install.sh) --as-version={0} --yes
      export PATH="$PATH:/usr/local/openvpn_as/scripts"
      for i in $(seq 1 60); do sacli status 2>/dev/null | grep -q '"api": "on"' && break; sleep 2; done
      sacli --key "host.name" --value "{1}" ConfigPut
      sacli --key "acme.ip_addresses.0" --value "{1}" ConfigPut
      sacli --key "acme.cert_profile" --value "shortlived" ConfigPut
      sacli start
      for i in $(seq 1 60); do sacli status 2>/dev/null | grep -q '"api": "on"' && break; sleep 2; done
      ADMIN_PW="$(echo '{2}' | base64 -d)"
      if [ -n "$ADMIN_PW" ]; then
        sacli --user openvpn --new_pass "$ADMIN_PW" SetLocalPassword >/dev/null && echo "openvpn password set from admin_pw parameter"
      else
        echo "admin_pw not set, using the auto-generated openvpn password:"
        grep -i 'Auto-generated pass = .*' /usr/local/openvpn_as/init.log
      fi
      unset ADMIN_PW
      echo y | sacli AcmeRegisterAccount
      sacli AcmeRequestCertificate
      exit 0
runcmd:
  - [ /usr/local/sbin/as-setup.sh ]
''', asVersion, pip.properties.ipAddress, base64(admin_pw))

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
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: take(replace(vmName, '_', '-'), 15)
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
output sshCommand string = 'ssh ${adminUsername}@${publicIp}'
