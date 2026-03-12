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
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47.0"
    }
  }
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

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

data "azuread_domains" "default" {
  only_default = true
}

locals {
  domain_name         = data.azuread_domains.default.domains[0].domain_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  subscription_id     = data.azurerm_subscription.current.subscription_id
  create_user_viewer  = "./create_user.sh ${var.elastic_apikey} ${var.organization_id} ${var.name}@maildrop.cc"
  destroy_user_viewer = "./delete_user.sh ${var.elastic_apikey} ${var.organization_id} ${var.name}@maildrop.cc"  
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

resource "azuread_invitation" "hobbyfarm_guest" {
  user_email_address = "${var.name}@maildrop.cc"
  user_display_name  = "Student ${var.name}"
  redirect_url = "https://portal.azure.com/#@${local.domain_name}/resource/subscriptions/${local.subscription_id}/resourcegroups/rg-${var.name}"

  message {
    body = "Bienvenue sur ton environnement Hobbyfarm ! Clique ci-dessous pour accéder à ton Resource Group."
  }
}

resource "azurerm_role_assignment" "rg_owner" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Owner"
  principal_id         = azuread_invitation.hobbyfarm_guest.user_id
}

resource "azuread_application" "student_app" {
  display_name = "app-${var.name}"
  owners       = [data.azurerm_client_config.current.object_id]
}

resource "azuread_service_principal" "student_sp" {
  client_id                    = azuread_application.student_app.client_id
  app_role_assignment_required = false
  owners                       = [data.azurerm_client_config.current.object_id]
}

resource "azuread_application_password" "student_sp_pwd" {
  application_id = azuread_application.student_app.id
  display_name   = "secret-${var.name}"
}

resource "azurerm_role_assignment" "sp_owner" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Owner"
  principal_id         = azuread_service_principal.student_sp.object_id
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
    name                       = "Custom"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
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

  user_data             = var.cloud-config == "" ? null : base64encode(var.cloud-config)
  
  custom_data = base64encode(<<-EOF
    #!/bin/bash

    curl -sSL https://raw.githubusercontent.com/sbeyn/es-course-img/refs/heads/main/setup.sh | bash -s

    EC_API_KEY="${try(jsondecode(restapi_object.student_api_key.api_response).key, "N/A")}"
    ARM_SUB="${local.subscription_id}"
    ARM_TENANT="${local.tenant_id}"
    ARM_CLIENT="${azuread_application.student_app.client_id}"
    ARM_SECRET="${azuread_application_password.student_sp_pwd.value}"

    cat <<PROFIL > /etc/profile.d/00-env.sh
    export EC_API_KEY="$EC_API_KEY"
    export ARM_SUBSCRIPTION_ID="$ARM_SUB"
    export ARM_TENANT_ID="$ARM_TENANT"
    export ARM_CLIENT_ID="$ARM_CLIENT"
    export ARM_CLIENT_SECRET="$ARM_SECRET"
    PROFIL

    chmod +x /etc/profile.d/00-env.sh

    rm -f /etc/update-motd.d/*

    cat <<'MOTD' > /etc/update-motd.d/99-hobbyfarm
    #!/bin/bash
    source /etc/profile.d/00-env.sh
    echo -e "╔══════════════════════════════════════════════════════════╗"
    echo -e "║  🚀  BIENVENUE SUR VOTRE LAB HOBBYFARM – ELASTIC & AZURE  ║"
    echo -e "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "  🌐 ACCES AZURE SERVICE PRINCIPAL"
    echo -e "     • Subscription ID : $ARM_SUBSCRIPTION_ID"
    echo -e "     • Client ID       : $ARM_CLIENT_ID"
    echo -e "     • Secret ID       : $ARM_CLIENT_SECRET"
    echo -e "     • Tenant ID       : $ARM_TENANT_ID"
    echo ""
    echo -e "  🔑 ACCES ELASTIC CLOUD"
    echo -e "     • API Key  : $EC_API_KEY"
    echo ""
    echo -e "────────────────────────────────────────────────────────────"
    echo -e "  ⚠️  Note : Pensez à détruire vos ressources après usage."
    echo ""
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

output "private_ip" {
  value = azurerm_network_interface.hobbyfarm_nic.private_ip_address
}

output "public_ip" {
  value = azurerm_public_ip.hobbyfarm_public_ip.ip_address
}

output "hostname" {
  value = azurerm_public_ip.hobbyfarm_public_ip.fqdn
}