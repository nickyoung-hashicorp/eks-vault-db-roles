##############################################################################
# Variables File
#
# Here is where we store the default values for all the variables used in our
# Terraform code. If you create a variable with no default, the user will be
# prompted to enter it (or define it via config file or command line flags.)

variable "prefix" {
  description = "This prefix will be included in the name of most resources."
  default = "nyoung"
}

variable "region" {
  description = "The region where the resources are created."
  default     = "us-west-2"
}

variable "address_space" {
  description = "The address space that is used by the virtual network. You can supply more than one address space. Changing this forces a new resource to be created."
  default     = "10.0.0.0/16"
}

variable "subnet_prefix_a" {
  description = "The address prefix to use for the A subnet."
  default     = "10.0.1.0/24"
}

variable "subnet_prefix_b" {
  description = "The address prefix to use for the B subnet."
  default     = "10.0.2.0/24"
}

variable "instance_type" {
  description = "Specifies the AWS instance type."
  default     = "t2.small"
}
