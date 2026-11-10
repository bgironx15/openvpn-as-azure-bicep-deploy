using './main.bicep'

param namePrefix = 'openvpn-as'
param hostname = 'openvpnas3'
param adminUsername = 'azureuser'

// Paste your full SSH public key between the triple quotes. Line breaks from pasting
// are removed automatically. Delete the trailing comment (e.g. user@host) to be safe.
param sshPublicKey = trim(replace(replace('''
<paste your SSH public key here>
''', '\r', ''), '\n', ''))

param adminSourceCidr = '<your.public.ip>/32'
param asVersion = '3.2.4'

// Required: password for the openvpn admin user (passed to Access Server as admin_pw).
param admin_password = '<your openvpn admin password>'
