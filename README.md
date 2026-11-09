# OpenVPN Access Server Deployment on Microsoft Azure Using Bicep

Deploys an Ubuntu 26.04 LTS Arm64 VM on Azure and installs OpenVPN Access Server with the official install script. On first boot, cloud-init also sets the Access Server hostname to the VM's public IP and requests a Let's Encrypt short-lived IP certificate through the Access Server ACME client.

## What gets deployed

| Resource | Details |
|---|---|
| Network security group | TCP 22, TCP 943, TCP 443, UDP 1194 open to any source (see Security) |
| Virtual network | `10.10.0.0/16` with subnet `10.10.1.0/24` |
| Public IP | Standard SKU, static, with a DNS label |
| Network interface | IP forwarding and accelerated networking enabled |
| Virtual machine | `Standard_D2pls_v6` (Arm64), Ubuntu 26.04 LTS Arm64, SSH key auth only |

## Files

| File | Purpose |
|---|---|
| `main.bicep` | The template |
| `main.bicepparam` | Example parameters with placeholders (committed) |
| `main.local.bicepparam` | Your real parameters (gitignored, create it yourself) |

## Prerequisites

- Azure CLI (`az`), or Azure Cloud Shell (Bash), where `az` and Bicep are preinstalled.
- An SSH key pair.
- At least 2 free vCPUs of regional and DPLSv6-family quota in the target region:

  ```bash
  az vm list-usage -l <region> --query "[?name.value=='cores' || contains(name.value,'DPLSv6')].{Quota:name.localizedValue, Used:currentValue, Limit:limit}" -o table
  ```

- Confirm the image and VM size are available in the region:

  ```bash
  az vm image list --publisher Canonical --offer ubuntu-26_04 --architecture Arm64 --all -o table
  az vm list-skus -l <region> --resource-type virtualMachines --size Standard_D2pls_v6 -o table
  ```

## Parameters

| Name | Default | Notes |
|---|---|---|
| `location` | resource group location | Any region with quota for the VM size |
| `namePrefix` | `openvpn-as` | Prefix for all resource names |
| `vmSize` | `Standard_D2pls_v6` | Arm64; the image must be Arm64 |
| `adminUsername` | `azureuser` | SSH user |
| `sshPublicKey` | (required) | Can be pasted across several lines in the params file; line breaks are stripped |
| `adminSourceCidr` | empty | Your public IP as a `/32`; swap it into the SSH and 943 rules to restrict them |
| `dnsLabel` | generated | Must be unique in the region |
| `asVersion` | `3.2.4` | Passed to the install script |
| `admin_pw` | empty | Password for the `openvpn` admin user. If empty, the auto-generated password is kept and written to `/var/log/as-setup.log` |
| `imageReference` | Canonical `ubuntu-26_04-lts` / `server-arm64` | Override if the offer or SKU differs |

## Deploy

```bash
cp main.bicepparam main.local.bicepparam    # then edit main.local.bicepparam

az login
az group create -n <resource-group> -l <region>

az deployment group what-if -g <resource-group> -f main.bicep -p main.local.bicepparam
az deployment group create  -g <resource-group> -f main.bicep -p main.local.bicepparam

az deployment group show -g <resource-group> -n main --query properties.outputs -o json
```

## Test

1. SSH in and wait for cloud-init to finish:

   ```bash
   ssh azureuser@<fqdn>
   cloud-init status --wait
   sudo tail -n 80 /var/log/as-setup.log
   ```

   The setup script ends with `exit 0`, so always check `/var/log/as-setup.log` rather than relying on the cloud-init status.

2. Check the service, version, listeners, and configuration:

   ```bash
   sudo systemctl status openvpnas --no-pager
   dpkg -l | grep openvpn-as
   sudo ss -tulpn | grep -E ':(443|943|1194)\b'
   sudo /usr/local/openvpn_as/scripts/sacli ConfigQuery | grep -E 'acme|host.name'
   ```

3. Get the `openvpn` admin password. If you set `admin_pw`, use that. Otherwise the auto-generated one is in the setup log:

   ```bash
   sudo grep -i "auto-generated pass" /var/log/as-setup.log
   ```

   To change it later:

   ```bash
   sudo /usr/local/openvpn_as/scripts/sacli --user openvpn --new_pass '<password>' SetLocalPassword
   ```

4. Verify the Let's Encrypt certificate from your machine:

   ```bash
   echo | openssl s_client -connect <public-ip>:443 2>/dev/null \
     | openssl x509 -noout -issuer -ext subjectAltName -dates
   ```

   Expect a Let's Encrypt issuer, `IP Address:<public-ip>` in the SAN, and about 6 days of validity.

5. Sign in to the Admin Web UI at `https://<public-ip>:943/admin`, create a test user, download a profile from `https://<public-ip>/`, and connect with OpenVPN Connect. Confirm the client appears in:

   ```bash
   sudo /usr/local/openvpn_as/scripts/sacli VPNStatus
   ```

## Clean up

```bash
az group delete -n <resource-group> --yes --no-wait
```

## Security

SSH (22) and the Admin/Client Web UI (943) are open to the internet by default. This is not recommended. To restrict them, set `adminSourceCidr` to your public IP as a `/32` and replace `sourceAddressPrefix: '*'` with `sourceAddressPrefix: adminSourceCidr` in those two rules in `main.bicep`. Change the auto-generated `openvpn` password soon after deploying, and consider enabling MFA for admin logins.

## Troubleshooting

| Error | Fix |
|---|---|
| `BCP004` string not terminated in the params file | The SSH key wrapped onto a new line inside a single-quoted string; use the triple-quoted format in `main.bicepparam` |
| `QuotaExceeded` | Deploy in another region (`param location = '<region>'`), deallocate unused VMs, or request a quota increase |
| `cannot boot with DiskControllerType 'NVMe'` | Do not set `diskControllerType` for this size |
| `SkuNotAvailable` | Choose another region or VM size |
