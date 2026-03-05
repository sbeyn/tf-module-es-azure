variable "public_key" {}
variable "image" {}
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

provider "azurerm" {
  features {}

  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
}

provider "ec" {
  apikey = var.elastic_apikey
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

resource "restapi_object" "student_api_key" {
  path         = "/users/auth/keys"
  query_string = ""
  data         = jsonencode({
    description = var.name
    expiration  = "1h"
    role_assignments = {
      organization = [
        {
          role_id         = "organization-admin"
          organization_id = var.organization_id
        }
      ]
    }
  })
  
  id_attribute = "id" 
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.name}"
  location = var.region
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

resource "ec_organization" "org" {
  members = {
    "${var.name}@maildrop.cc" = {
      deployment_roles = [
        {
          role            = "viewer"
          all_deployments = true
        }
      ]
    }
  }
}

output "generated_ec_api_key" {
  value     = jsondecode(restapi_object.student_api_key.api_response).key
  sensitive = true
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
