# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DEPLOY A EKS CLUSTER WITH EC2 INSTANCES AS WORKERS AND CONFIGURE IAM BINDINGS
# These templates show an example of how to:
# - Deploy an EKS cluster
# - Deploy a self managed Autoscaling Group (ASG) with EC2 instances acting as workers
# - Bind IAM Roles to Kubernetes RBAC Groups for cluster access, using test IAM roles as an example
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

terraform {
  # This module has been updated with 0.12 syntax, which means it is no longer compatible with any versions below 0.12.
  required_version = ">= 0.12"
}

# ------------------------------------------------------------------------------
# CONFIGURE OUR AWS CONNECTION
# ------------------------------------------------------------------------------

provider "aws" {
  # Most recent provider version as of 2020-02-18
  version = "~> 2.49"

  region = var.aws_region
}
#this is a test.
terraform {
  backend "s3" {
    encrypt        = true
    region         = "us-west-2"
    bucket         = "terraform-cdk-aws-athenaplatform-dev"
    dynamodb_table = "terraform-cdk-aws-athenaplatform-dev"
  }
}

data "aws_availability_zones" "available" {
}

#############################################################################################
#                     VPC and Subnet taggings as per K8 EKS requirements                    #
#############################################################################################

data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = ["us-west-2_athena_${var.env}_vpc"]
  }
}

data "aws_subnet_ids" "dmz_subnet" {

  vpc_id = data.aws_vpc.selected.id

  tags = {
    Name = "*_DMZ"
  }
}

data "aws_subnet_ids" "eks_subnet" {

  vpc_id = data.aws_vpc.selected.id

  tags = {
    Name = "*_EKS"
  }
}

resource "null_resource" "subnet_tags" {
  count = length(data.aws_subnet_ids.dmz_subnet.ids)

  provisioner "local-exec" {
    command = "aws ec2 create-tags --resources ${data.aws_vpc.selected.id} --tags Key=kubernetes.io/cluster/eks_${var.prodid}_${var.env},,Value=shared"
  }
  provisioner "local-exec" {
    when = destroy
    command = "aws ec2 delete-tags --resources ${data.aws_vpc.selected.id} --tags Key=kubernetes.io/cluster/eks_${var.prodid}_${var.env},,Value=shared"
  }

  provisioner "local-exec" {
    command = "aws ec2 create-tags --resources ${element(flatten([data.aws_subnet_ids.dmz_subnet.ids]), count.index)} --tags Key=kubernetes.io/cluster/eks_${var.prodid}_${var.env},,Value=shared"
  }
  provisioner "local-exec" {
    when = destroy
    command = "aws ec2 delete-tags --resources ${element(flatten([data.aws_subnet_ids.dmz_subnet.ids]), count.index)} --tags Key=kubernetes.io/cluster/eks_${var.prodid}_${var.env},,Value=shared"
  }
  provisioner "local-exec" {
    command = "aws ec2 create-tags --resources ${element(flatten([data.aws_subnet_ids.dmz_subnet.ids]), count.index)} --tags Key=kubernetes.io/role/elb,Value=1"
  }

  provisioner "local-exec" {
    command = "aws ec2 create-tags --resources ${element(flatten([data.aws_subnet_ids.eks_subnet.ids]), count.index)} --tags Key=kubernetes.io/cluster/eks_${var.prodid}_${var.env},,Value=shared"
  }
  provisioner "local-exec" {
    when = destroy
    command = "aws ec2 delete-tags --resources ${element(flatten([data.aws_subnet_ids.eks_subnet.ids]), count.index)} --tags Key=kubernetes.io/cluster/eks_${var.prodid}_${var.env},,Value=shared"
  }
  provisioner "local-exec" {
    command = "aws ec2 create-tags --resources ${element(flatten([data.aws_subnet_ids.eks_subnet.ids]), count.index)} --tags Key=kubernetes.io/role/internal-elb,Value=1"
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE OUR KUBERNETES CONNECTIONS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


provider "kubernetes" {

  version = "= 1.10.0"

  load_config_file       = false
  host                   = data.template_file.kubernetes_cluster_endpoint.rendered
  cluster_ca_certificate = base64decode(data.template_file.kubernetes_cluster_ca.rendered)
  token                  = data.aws_eks_cluster_auth.kubernetes_token.token
}

data "template_file" "kubernetes_cluster_endpoint" {
  template = module.eks_cluster.eks_cluster_endpoint
}

data "template_file" "kubernetes_cluster_ca" {
  template = module.eks_cluster.eks_cluster_certificate_authority
}

data "aws_eks_cluster_auth" "kubernetes_token" {
  name = module.eks_cluster.eks_cluster_name
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE Worker nodes
# ---------------------------------------------------------------------------------------------------------------------

# Allowing access to all CDK CIDR-Block.

resource "aws_security_group_rule" "rule1" {
  protocol                 = "tcp"
  security_group_id        = module.eks_cluster.eks_master_security_group_id
  cidr_blocks              = ["139.126.0.0/16", "172.30.0.0/15", "100.126.0.0/16", "100.77.0.0/21", "100.81.0.0/21", "100.66.59.179/32"]
  from_port                = 443
  to_port                  = 443
  type                     = "ingress"
  description              = "Connectivity inbound from CDK networks"
}

module "eks_workers" {

  source = "git::git@github.com:gruntwork-io/terraform-aws-eks.git//modules/eks-cluster-workers?ref=v0.19.1"

  cluster_name                 = "eks_${var.prodid}_${var.env}"
  eks_master_security_group_id = module.eks_cluster.eks_master_security_group_id

  autoscaling_group_configurations = {
    asg = {
      min_size   = 3
      max_size   = 6
      subnet_ids = flatten(["${data.aws_subnet_ids.eks_subnet.*.ids}"])
      tags       = []
    }
  }
  additional_security_group_ids                = [data.aws_security_group.network_additional_sg.id]
  cluster_instance_ami                         = data.aws_ami.eks_worker.id
  cluster_instance_type                        = "t3.medium"
  cluster_instance_keypair_name                = var.eks_worker_keypair_name
  cluster_instance_user_data                   = data.template_cloudinit_config.cloud_init.rendered
  cluster_instance_associate_public_ip_address = true
   
  vpc_id = data.aws_vpc.selected.id
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE EKS CLUSTER IN TO THE VPC
# ---------------------------------------------------------------------------------------------------------------------

module "eks_cluster" {

  source = "git::git@github.com:gruntwork-io/terraform-aws-eks.git//modules/eks-cluster-control-plane?ref=v0.19.1"

  cluster_name                 = "eks_${var.prodid}_${var.env}"
  enabled_cluster_log_types    = ["api"]

  vpc_id                = data.aws_vpc.selected.id
  vpc_master_subnet_ids = flatten(["${data.aws_subnet_ids.eks_subnet.*.ids}"])

  kubernetes_version                           = var.kubernetes_version
  endpoint_public_access                       = var.endpoint_public_access
  endpoint_public_access_cidrs                 = var.endpoint_public_access_cidrs
  use_kubergrunt_verification                  = false
  configure_kubectl                            = false
  configure_openid_connect_provider            = true
}

data "aws_security_group" "network_additional_sg" {
  filter {
    name   = "tag:color"
    values = ["eks"]
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE EKS IAM ROLE MAPPINGS
# We will map AWS IAM roles to RBAC roles in Kubernetes. By doing so, we:
# - allow access to the EKS cluster when assuming mapped IAM role
# - manage authorization for those roles using RBAC role resources in Kubernetes
# At a minimum, we need to provide cluster node level permissions to the IAM role assumed by EKS workers.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

data "aws_iam_user" "bamboo_orchestration" {
  user_name = "svc_terraform_orchestration"
}

data "aws_iam_user" "svc_ansible_orchestration" {
  user_name = "svc_ansible_orchestration"
}

module "eks_k8s_role_mapping" {
  # When using these modules in your own templates, you will need to use a Git URL with a ref attribute that pins you
  # to a specific version of the modules, such as the following example:
  source = "git::git@github.com:gruntwork-io/terraform-aws-eks.git//modules/eks-k8s-role-mapping?ref=v0.19.1"
  #source = "../../modules/eks-k8s-role-mapping"

  eks_worker_iam_role_arns = [module.eks_workers.eks_worker_iam_role_arn]

  iam_role_to_rbac_group_mappings = {
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/cdk_aws_athenaplatform_operations"     = ["system:masters"]
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/cdk_aws_athenaplatform_developers"     = ["${(var.env == "dev" ? "admin-role" : "read-role")}"]
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/cdk_aws_athenaplatform_administrators" = ["system:masters"]
  }

  iam_user_to_rbac_group_mappings = {
    "${data.aws_iam_user.bamboo_orchestration.arn}"      = ["system:masters"]
    "${data.aws_iam_user.svc_ansible_orchestration.arn}" = ["system:masters"]
  }

  config_map_labels = {
    "eks-cluster" = module.eks_cluster.eks_cluster_name
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CREATE EXAMPLE IAM ROLES AND USERS
# We create example IAM roles that can be used to test and experiment with mapping different IAM roles/users to groups
# in Kubernetes with different permissions.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
/*
resource "aws_iam_role" "example" {
  name               = "${var.example_iam_role_name_prefix}${var.unique_identifier}"
  assume_role_policy = data.aws_iam_policy_document.allow_access_from_self.json
}

resource "aws_iam_role_policy" "example" {
  name   = "${var.example_iam_role_name_prefix}${var.unique_identifier}-policy"
  role   = aws_iam_role.example.id
  policy = data.aws_iam_policy_document.example.json
}

# Minimal permission to be able to authenticate to the cluster
data "aws_iam_policy_document" "example" {
  statement {
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks_cluster.eks_cluster_arn]
  }
}
*/