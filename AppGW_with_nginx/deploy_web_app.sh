#!/bin/bash

# --- Configuration Variables ---
RESOURCE_GROUP="waf"
LOCATION="westus3"
VM_NAME="web-vm"
VM_SIZE="Standard_B2s" # B2 series VM
VM_IMAGE="Ubuntu2404"
VM_ADMIN_USER="azureuser" # Choose a secure admin username
VNET_NAME="app-vnet"
VM_SUBNET_NAME="vm-subnet"
VM_SUBNET_PREFIX="10.0.1.0/24"
AGW_SUBNET_NAME="agw-subnet"
AGW_SUBNET_PREFIX="10.0.2.0/24"
VM_PUBLIC_IP_NAME="vm-pip"
AGW_PUBLIC_IP_NAME="agw-pip"
NIC_NAME="vm-nic"
NSG_NAME="vm-nsg"
AGW_NAME="app-gateway"
WAF_POLICY_NAME="app-waf-policy"
CLOUD_INIT_FILE="cloud-init-nginx.txt" # Path to the cloud-init script

# --- Script Start ---
echo "Starting Azure resource deployment..."

# 1. Create Resource Group
echo "Creating resource group: $RESOURCE_GROUP in $LOCATION..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
if [ $? -ne 0 ]; then echo "Error creating resource group."; exit 1; fi
echo "Resource group created successfully."

# 2. Create Virtual Network
echo "Creating virtual network: $VNET_NAME..."
az network vnet create \
  --name "$VNET_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --address-prefix 10.0.0.0/16 \
  --output none
if [ $? -ne 0 ]; then echo "Error creating virtual network."; exit 1; fi
echo "Virtual network created successfully."

# 3. Create Subnet for VM
echo "Creating VM subnet: $VM_SUBNET_NAME..."
az network vnet subnet create \
  --name "$VM_SUBNET_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --address-prefixes "$VM_SUBNET_PREFIX" \
  --output none
if [ $? -ne 0 ]; then echo "Error creating VM subnet."; exit 1; fi
echo "VM subnet created successfully."

# 4. Create Subnet for Application Gateway (must be dedicated)
echo "Creating Application Gateway subnet: $AGW_SUBNET_NAME..."
az network vnet subnet create \
  --name "$AGW_SUBNET_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --address-prefixes "$AGW_SUBNET_PREFIX" \
  --output none
if [ $? -ne 0 ]; then echo "Error creating Application Gateway subnet."; exit 1; fi
echo "Application Gateway subnet created successfully."

# 5. Create Public IP for VM (Optional but useful for direct access/testing)
echo "Creating Public IP for VM: $VM_PUBLIC_IP_NAME..."
az network public-ip create \
  --name "$VM_PUBLIC_IP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --allocation-method Static \
  --sku Standard \
  --output none
if [ $? -ne 0 ]; then echo "Error creating VM Public IP."; exit 1; fi
echo "VM Public IP created successfully."

# 6. Create Public IP for Application Gateway
echo "Creating Public IP for Application Gateway: $AGW_PUBLIC_IP_NAME..."
az network public-ip create \
  --name "$AGW_PUBLIC_IP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --allocation-method Static \
  --sku Standard \
  --output none
if [ $? -ne 0 ]; then echo "Error creating Application Gateway Public IP."; exit 1; fi
echo "Application Gateway Public IP created successfully."

# 7. Create Network Security Group (NSG)
echo "Creating Network Security Group: $NSG_NAME..."
az network nsg create \
  --name "$NSG_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none
if [ $? -ne 0 ]; then echo "Error creating NSG."; exit 1; fi
echo "NSG created successfully."

# 8. Create NSG rule to allow HTTP (Port 80) - App Gateway will talk to VM
# You might restrict source to AGW subnet later for better security
echo "Creating NSG rule to allow HTTP traffic..."
az network nsg rule create \
  --name Allow-HTTP-Inbound \
  --nsg-name "$NSG_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --priority 1000 \
  --access Allow \
  --protocol Tcp \
  --direction Inbound \
  --destination-port-ranges 80 \
  --source-address-prefixes '*' \
  --destination-address-prefixes '*' \
  --output none
if [ $? -ne 0 ]; then echo "Error creating NSG rule."; exit 1; fi
echo "NSG rule created successfully."

# 9. Create Network Interface (NIC) for VM
echo "Creating Network Interface for VM: $NIC_NAME..."
az network nic create \
  --name "$NIC_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --vnet-name "$VNET_NAME" \
  --subnet "$VM_SUBNET_NAME" \
  --network-security-group "$NSG_NAME" \
  --public-ip-address "$VM_PUBLIC_IP_NAME" \
  --output none
if [ $? -ne 0 ]; then echo "Error creating NIC."; exit 1; fi
echo "NIC created successfully."

# 10. Create Virtual Machine with Nginx using cloud-init
echo "Creating Virtual Machine: $VM_NAME..."
echo "This step might take a few minutes..."
az vm create \
  --name "$VM_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --size "$VM_SIZE" \
  --image "$VM_IMAGE" \
  --nics "$NIC_NAME" \
  --admin-username "$VM_ADMIN_USER" \
  --generate-ssh-keys \
  --custom-data "$CLOUD_INIT_FILE" \
  --output none
if [ $? -ne 0 ]; then echo "Error creating Virtual Machine."; exit 1; fi
echo "Virtual Machine created successfully."

# Get VM NIC details needed for Application Gateway backend pool
VM_NIC_ID=$(az network nic show --name "$NIC_NAME" --resource-group "$RESOURCE_GROUP" --query "id" -o tsv)
if [ -z "$VM_NIC_ID" ]; then echo "Error retrieving VM NIC ID."; exit 1; fi
VM_IPCONFIG_ID=$(az network nic ip-config show --name "ipconfig1" --nic-name "$NIC_NAME" --resource-group "$RESOURCE_GROUP" --query "id" -o tsv)
if [ -z "$VM_IPCONFIG_ID" ]; then echo "Error retrieving VM IP Config ID."; exit 1; fi

# 11. Create WAF Policy
echo "Creating WAF Policy: $WAF_POLICY_NAME..."
az network application-gateway waf-policy create \
  --name "$WAF_POLICY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none
if [ $? -ne 0 ]; then echo "Error creating WAF Policy."; exit 1; fi
echo "WAF Policy created successfully."

# 12. Configure WAF Policy Settings (Mode: Detection, Standard Ruleset)
echo "Configuring WAF Policy settings..."
# Set mode to Detection (Monitor)
az network application-gateway waf-policy policy-setting update \
  --resource-group "$RESOURCE_GROUP" \
  --mode Detection \
  --state Enabled \
  --policy-name "$WAF_POLICY_NAME" \
  --output none
if [ $? -ne 0 ]; then echo "Error updating WAF Policy settings."; exit 1; fi

# Add the OWASP 3.2 managed rule set (adjust version if needed)
# Use 'update' instead of 'add' to handle potential pre-existing default rule sets
az network application-gateway waf-policy managed-rule rule-set update \
    --policy-name "$WAF_POLICY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --type OWASP \
    --version 3.2 \
    --output none
if [ $? -ne 0 ]; then echo "Error updating managed rule set for WAF Policy."; exit 1; fi # Updated error message
echo "WAF Policy managed rule set configured successfully." # Updated success message

# Get WAF Policy ID
WAF_POLICY_ID=$(az network application-gateway waf-policy show --name "$WAF_POLICY_NAME" --resource-group "$RESOURCE_GROUP" --query "id" -o tsv)
if [ -z "$WAF_POLICY_ID" ]; then echo "Error retrieving WAF Policy ID."; exit 1; fi

# 13. Create Application Gateway with WAF
echo "Creating Application Gateway: $AGW_NAME..."
echo "This step might take several minutes..."
az network application-gateway create \
  --name "$AGW_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku WAF_v2 \
  --public-ip-address "$AGW_PUBLIC_IP_NAME" \
  --vnet-name "$VNET_NAME" \
  --subnet "$AGW_SUBNET_NAME" \
  --http-settings-protocol Http \
  --http-settings-port 80 \
  --frontend-port 80 \
  --routing-rule-type Basic \
  --waf-policy "$WAF_POLICY_ID" \
  --priority 100 \
  --output none
# Note: We add the backend pool target separately after creation

if [ $? -ne 0 ]; then echo "Error creating Application Gateway."; exit 1; fi
echo "Application Gateway created successfully (initial setup)."

# 14. Add VM NIC IP Configuration to Application Gateway Backend Pool
echo "Adding VM to Application Gateway backend pool..."
# The 'az network application-gateway create' command with '--routing-rule-type Basic'
# typically creates default resources:
# - Backend Pool: appGatewayBackendPool
# - HTTP Setting: appGatewayBackendHttpSettings
# - Listener:     appGatewayHttpListener
# - Routing Rule: rule1
# We update the default backend pool 'appGatewayBackendPool' here.
az network application-gateway address-pool update \
    --gateway-name "$AGW_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name appGatewayBackendPool \
    --add backendIpConfigurations "{'id':'$VM_IPCONFIG_ID'}" \
    --output none

# Check if the previous command succeeded before proceeding
if [ $? -ne 0 ]; then echo "Error adding VM to Application Gateway backend pool."; exit 1; fi
echo "VM added to backend pool successfully."

# --- Script End ---
echo "Azure deployment script finished."

# Output the Application Gateway Public IP Address
AGW_PIP_ADDRESS=$(az network public-ip show --name "$AGW_PUBLIC_IP_NAME" --resource-group "$RESOURCE_GROUP" --query "ipAddress" -o tsv)
echo "-----------------------------------------------------"
echo "Application Gateway Public IP: $AGW_PIP_ADDRESS"
echo "Access your application at: http://$AGW_PIP_ADDRESS"
echo "-----------------------------------------------------"

# Output the VM Public IP Address for direct access (if needed)
VM_PIP_ADDRESS=$(az network public-ip show --name "$VM_PUBLIC_IP_NAME" --resource-group "$RESOURCE_GROUP" --query "ipAddress" -o tsv)
echo "VM Direct Public IP: $VM_PIP_ADDRESS"
echo "-----------------------------------------------------"
