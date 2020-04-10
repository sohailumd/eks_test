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
# CREATE THE EKS CLUSTER IN TO THE VPC
# ---------------------------------------------------------------------------------------------------------------------

module "eks_cluster" {

  source = "git::git@github.com:gruntwork-io/terraform-aws-eks.git//modules/eks-cluster-control-plane?ref=v0.19.1"

  cluster_name                 = "eks_${var.prodid}_${var.env}"
  enabled_cluster_log_types    = ["api"]

  vpc_id                = data.aws_vpc.selected.id
  vpc_master_subnet_ids = flatten(["${data.aws_subnet_ids.eks_subnet.*.ids}"])

  kubernetes_version                           = var.kubernetes_version
  endpoint_public_access_cidrs                 = var.endpoint_public_access_cidrs
  use_kubergrunt_verification                  = false
  configure_kubectl                            = false
  configure_openid_connect_provider            = true
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

  cluster_instance_ami                         = data.aws_ami.eks_worker.id
  cluster_instance_type                        = "t3.medium"
  cluster_instance_keypair_name                = var.eks_worker_keypair_name
  cluster_instance_user_data                   = data.template_cloudinit_config.cloud_init.rendered
  cluster_instance_associate_public_ip_address = true

  vpc_id = data.aws_vpc.selected.id
}

# Allowing SSH from anywhere to the worker nodes for test purposes only.
# THIS SHOULD NOT BE DONE IN PROD
resource "aws_security_group_rule" "allow_inbound_ssh_from_anywhere" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.eks_workers.eks_worker_security_group_id
}

# Allowing access to node ports on the worker nodes for test purposes only.
# THIS SHOULD NOT BE DONE IN PROD. INSTEAD USE LOAD BALANCERS.
resource "aws_security_group_rule" "allow_inbound_node_port_from_anywhere" {
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.eks_workers.eks_worker_security_group_id
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE EKS IAM ROLE MAPPINGS
# We will map AWS IAM roles to RBAC roles in Kubernetes. By doing so, we:
# - allow access to the EKS cluster when assuming mapped IAM role
# - manage authorization for those roles using RBAC role resources in Kubernetes
# At a minimum, we need to provide cluster node level permissions to the IAM role assumed by EKS workers.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
/*
module "eks_k8s_role_mapping" {

  source = "git::git@github.com:gruntwork-io/terraform-aws-eks.git//modules/eks-k8s-role-mapping?ref=v0.19.1"

  eks_worker_iam_role_arns = [module.eks_workers.eks_worker_iam_role_arn]
  iam_user_to_rbac_group_mappings = {
      "userarn"   = ["arn:aws:iam::637576413111:user/cicd/svc_ansible_orchestration"]
      "username"  = ["svc_ansible_orchestration"]
      "groups"    = ["system:masters"]
  }

  iam_role_to_rbac_group_mappings = {
    "${aws_iam_role.example.arn}" = [var.example_iam_role_kubernetes_group_name]
    "${local.caller_real_arn}"    = ["system:masters"]
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