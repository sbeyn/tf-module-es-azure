variable "public_key" {}
variable "disk" {}
variable "instance_type" {}
variable "name" {}
variable "ssh_username" {}
variable "image_publisher" {}
variable "image_offer" {}
variable "image_sku" {}
variable "image_version" {}
variable "client_id" {}
variable "client_secret" {}
variable "tenant_id" {}
variable "subscription_id" {}
variable "source_address_prefix" {}
variable "region" {}
variable "tag_provisioner" {
  default = "terraform"
}
variable "tag_owner" {
  default = "hobbyfarm"
}
variable "cloud-config" {}
variable "elastic_apikey" {}
variable "organization_id" {}

terraform {
  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = "1.19.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47.0"
    }
  }
}

variable "elastic_privatelink_alias" {
  description = "L'alias du service Private Link fourni par Elastic pour votre région"
  default     = "westeurope-prod-001-privatelink-service.190cd496-6d79-4ee2-8f23-0667fd5a8ec1.westeurope.azure.privatelinkservice"
}

variable "elastic_dns_zone_name" {
  description = "Le nom de la zone DNS (ex: privatelink.eastus2.azure.elastic-cloud.com)"
  default     = "privatelink.westeurope.azure.elastic-cloud.com"
}

provider "azuread" {
  client_id     = var.client_id
  client_secret = var.client_secret
  tenant_id     = var.tenant_id
}

provider "azurerm" {
  features {}

  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
}

provider "restapi" {
  uri                  = "https://api.elastic-cloud.com/api/v1"
  write_returns_object = true
  debug                = false

  headers = {
    "Authorization" = "ApiKey ${var.elastic_apikey}"
    "Content-Type"  = "application/json"
  }
}

locals {
  create_user_viewer = "./create_user.sh ${var.elastic_apikey} ${var.organization_id} ${var.name}@maildrop.cc"
  destroy_user_viewer = "./delete_user.sh ${var.elastic_apikey} ${var.organization_id} ${var.name}@maildrop.cc"  
}

data "azuread_domains" "default" {
  only_default = true
}

resource "restapi_object" "student_api_key" {
  path         = "/users/auth/keys"
  query_string = ""
  data         = jsonencode({
    description = var.name
    expiration  = "1d"
    role_assignments = {
      organization = [
        {
          role_id         = "organization-admin"
          organization_id = var.organization_id
        }
      ]
    }
  })
  destroy_path   = "/users/auth/keys/{id}" 
  destroy_method = "DELETE"
  lifecycle {
    ignore_changes  = [api_response, data]
  }

  id_attribute = "id" 
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.name}"
  location = var.region
}

resource "random_password" "hobbyfarm_user_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "azuread_user" "hobbyfarm_user" {
  user_principal_name = "${var.name}@${data.azuread_domains.default.domains[0].domain_name}"
  display_name        = "Hobbyfarm Student ${var.name}"
  password            = random_password.hobbyfarm_user_password.result
  mail                = "${var.name}@maildrop.cc"
  
  force_password_change = false
}

resource "azurerm_role_assignment" "rg_owner" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Owner"
  principal_id         = azuread_user.hobbyfarm_user.object_id
}

resource "azurerm_virtual_network" "hobbyfarm_network" {
  name                = "vnet-${var.name}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "hobbyfarm_subnet" {
  name                 = "snet-${var.name}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.hobbyfarm_network.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_private_endpoint" "elastic_pe" {
  name                 = "pe-elastic-${var.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.hobbyfarm_subnet.id

  private_service_connection {
    name                           = "psc-elastic-${var.name}"
    private_connection_resource_alias = var.elastic_privatelink_alias
    is_manual_connection           = true
    request_message                = "Connexion depuis Hobbyfarm ${var.name}"
  }
}

resource "azurerm_private_dns_zone" "elastic_dns" {
  name                = var.elastic_dns_zone_name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "elastic_dns_link" {
  name                  = "vnet-link-elastic"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.elastic_dns.name
  virtual_network_id    = azurerm_virtual_network.hobbyfarm_network.id
}

resource "azurerm_private_dns_a_record" "elastic_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.elastic_dns.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.elastic_pe.private_service_connection[0].private_ip_address]
}

resource "azurerm_public_ip" "hobbyfarm_public_ip" {
  name                = "pip-${var.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "hobbyfarm_nsg" {
  name                = "nsg-${var.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.source_address_prefix
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "hobbyfarm_nic" {
  name                = "nic-${var.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "my_nic_configuration"
    subnet_id                     = azurerm_subnet.hobbyfarm_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.hobbyfarm_public_ip.id
  }
}

resource "azurerm_network_interface_security_group_association" "hobbyfarm" {
  network_interface_id      = azurerm_network_interface.hobbyfarm_nic.id
  network_security_group_id = azurerm_network_security_group.hobbyfarm_nsg.id
}

resource "azurerm_linux_virtual_machine" "hobbyfarm_vm" {
  name                  = var.name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.hobbyfarm_nic.id]
  size                  = var.instance_type

  user_data             = var.cloud-config == "" ? null : var.cloud-config
  
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    
    mkdir -p /etc/hobbyfarm
    
    ELASTIC_KEY="${try(jsondecode(restapi_object.student_api_key.api_response).key, "N/A")}"
    AZ_LOGIN="${azuread_user.hobbyfarm_user.user_principal_name}"
    AZ_PASS="${random_password.hobbyfarm_user_password.result}"
    
    echo "$ELASTIC_KEY" > /etc/hobbyfarm/elastic_api_key
    echo "$AZ_PASS" > /etc/hobbyfarm/azure_password
    chmod 700 /etc/hobbyfarm
    chmod 600 /etc/hobbyfarm/*

    rm -f /etc/update-motd.d/*

    cat <<'MOTD' > /etc/update-motd.d/99-hobbyfarm
    #!/bin/bash
    echo -e "\e[1;34m##########################################################\e[0m"
    echo -e "\e[1;34m#           BIENVENUE SUR TON LAB HOBBYFARM              #\e[0m"
    echo -e "\e[1;34m##########################################################\e[0m"
    echo ""
    echo -e "\e[1;32m--- ACCÈS AZURE ---\e[0m"
    echo -e "Login    : ${AZ_LOGIN}"
    echo -e "Password : ${AZ_PASS}"
    echo ""
    echo -e "\e[1;32m--- ACCÈS ELASTIC ---\e[0m"
    echo -e "API Key  : ${ELASTIC_KEY}"
    echo ""
    echo -e "\e[1;33mInfos utiles :\e[0m"
    echo -e "Les credentials sont stockés dans /etc/hobbyfarm/"
    echo -e "\e[1;34m##########################################################\e[0m"
    MOTD

    chmod +x /etc/update-motd.d/99-hobbyfarm
  EOF
  )

  tags = {
    Name        = var.name
    Owner       = var.tag_owner
    provisioner = var.tag_provisioner
  }

  os_disk {
    name                 = "myOsDisk"
    disk_size_gb         = var.disk
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  computer_name  = "hostname"
  admin_username = var.ssh_username

  admin_ssh_key {
    username   = var.ssh_username
    public_key = var.public_key
  }

}

resource "null_resource" "lifecycle-elastic-member" {
  triggers = {
    destroy_user_viewer = local.destroy_user_viewer
  }
  provisioner "local-exec" {
    when       = create
    command    = local.create_user_viewer
  }
  provisioner "local-exec" {
    when       = destroy
    command    = self.triggers.destroy_user_viewer
    on_failure = continue
  }
}

output "password_azure" {
  value     = random_password.hobbyfarm_user_password.result
  sensitive = true
}

output "generated_ec_api_key" {
  value     = try(jsondecode(restapi_object.student_api_key.api_response).key, "None")
}

output "private_ip" {
  value = azurerm_network_interface.hobbyfarm_nic.private_ip_address
}

output "public_ip" {
  value = azurerm_public_ip.hobbyfarm_public_ip.ip_address
}

output "hostname" {
  value = azurerm_public_ip.hobbyfarm_public_ip.fqdn
}
