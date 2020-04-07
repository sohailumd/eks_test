# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DATA SOURCES
# These resources must already exist.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Use the default EKS optimized AMI available in the region.
data "aws_ami" "eks_worker" {
  filter {
    name   = "name"
    values = ["amazon-eks-node-${var.kubernetes_version}-v*"]
  }

  most_recent = true
  owners      = ["602401143452"] # Amazon EKS AMI Account ID
}

# Use cloud-init script to initialize the EKS workers
data "template_cloudinit_config" "cloud_init" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "eks-workers-default-cloud-init"
    content_type = "text/x-shellscript"
    content      = data.template_file.user_data.rendered
  }
}

data "template_file" "user_data" {
  template = file("${path.module}/user-data/user-data.sh")

  vars = {
    user_data_text            = var.user_data_text
    eks_cluster_name          = "eks_${var.prodid}_${var.env}"
    eks_endpoint              = module.eks_cluster.eks_cluster_endpoint
    eks_certificate_authority = module.eks_cluster.eks_cluster_certificate_authority
  }
}
/*
# Get the subnet ids while taking into account the availability zone whitelist.
# Here we are using public subnets for testing purposes, but in production you should use private subnets.
data "aws_subnet" "all" {
  count = module.vpc_app.num_availability_zones
  id    = element(module.vpc_app.public_subnet_ids, count.index)
}
*/
locals {
  # Get the list of availability zones to use for the cluster and node based on the whitelist.
  # Here, we use an awkward join and split because Terraform does not support conditional ternary expressions with list
  # values. See https://github.com/hashicorp/terraform/issues/12453
  /*
  availability_zones = split(
    ",",
    length(var.availability_zone_whitelist) == 0 ? join(",", data.aws_subnet.all.*.availability_zone) : join(",", var.availability_zone_whitelist),
  )

  usable_subnet_ids = matchkeys(
    data.aws_subnet.all.*.id,
    data.aws_subnet.all.*.availability_zone,
    local.availability_zones,
  )
*/
  # The caller identity ARN is not exactly the IAM Role ARN when it is an assumed role: it corresponds to an STS
  # AssumedRole ARN. Therefore, we need to massage the data to morph it into the actual IAM Role ARN when it is an
  # assumed-role.
  caller_arn_type = length(regexall("assumed-role", data.aws_caller_identity.current.arn)) > 0 ? "assumed-role" : "user"
  caller_arn_name = replace(data.aws_caller_identity.current.arn, "/.*(assumed-role|user)/([^/]+).*/", "$2")
  caller_real_arn = (
    local.caller_arn_type == "user"
    ? data.aws_caller_identity.current.arn
    : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.caller_arn_name}"
  )
}

# We only want to allow entities in this account to be able to assume the example role
data "aws_iam_policy_document" "allow_access_from_self" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.caller_real_arn]
    }
  }
}

data "aws_caller_identity" "current" {}
