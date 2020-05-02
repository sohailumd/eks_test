# ---------------------------------------------------------------------------------------------------------------------
# ENVIRONMENT VARIABLES
# Define these secrets as environment variables
# ---------------------------------------------------------------------------------------------------------------------

# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY

# ---------------------------------------------------------------------------------------------------------------------
# MODULE PARAMETERS
# These variables are expected to be passed in by the operator
# ---------------------------------------------------------------------------------------------------------------------

variable "prodid"{}

variable "env" {}

variable "aws_region" {
  description = "The AWS region in which all resources will be created. You must use a region with EKS available."
  type        = string
  default     = "us-west-2"
}

#variable "eks_cluster_name" {
 # description = "The name of the EKS cluster."
  #type        = string
#}

# NOTE: Setting this to a CIDR block that you do not own will prevent your ability to reach the API server. You will
# also be unable to configure the EKS IAM role mapping remotely through this terraform code.
variable "endpoint_public_access_cidrs" {
  description = "A list of CIDR blocks that should be allowed network access to the Kubernetes public API endpoint. When null or empty, allow access from the whole world (0.0.0.0/0). Note that this only restricts network reachability to the API, and does not account for authentication to the API."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "endpoint_public_access" {
  description = "Whether or not to enable public API endpoints which allow access to the Kubernetes API from outside of the VPC."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These variables have defaults and may be overwritten
# ---------------------------------------------------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Version of Kubernetes to use. Refer to EKS docs for list of available versions (https://docs.aws.amazon.com/eks/latest/userguide/platform-versions.html)."
  type        = string
  default     = "1.15"
}

variable "availability_zone_whitelist" {
  description = "A list of availability zones in the region that we can use to deploy the cluster. You can use this to avoid availability zones that may not be able to provision the resources (e.g ran out of capacity). If empty, will allow all availability zones."
  type        = list(string)
  default     = []
}

variable "eks_worker_keypair_name" {
  description = "The public SSH key to be installed on the worker nodes for testing purposes."
  type        = string
  default     = null
}

variable "additional_security_group_ids" {
  description = "A list of additional Security Groups IDs to be attached on the EKS Worker."
  type        = list(string)
  default     = []
}

variable "user_data_text" {
  description = "This is purely here for testing purposes. We modify the user_data_text variable at test time to make sure updates to the EKS cluster instances can be rolled out without downtime."
  type        = string
  default     = "Hello World"
}

variable "unique_identifier" {
  description = "A unique identifier that can be used to index the test IAM resources"
  type        = string
  default     = ""
}

variable "example_iam_role_name_prefix" {
  description = "Prefix of the name for the IAM role to create as an example. The final name is this prefix with the unique_identifier appended to it."
  type        = string
  default     = ""
}

variable "example_iam_role_kubernetes_group_name" {
  description = "Name of the group to map the example IAM role to."
  type        = string
  default     = "system:authenticated"
}

variable "wait_for_component_upgrade_rollout" {
  description = "Whether or not to wait for component upgrades to roll out to the cluster."
  type        = bool
  # Disable waiting for rollout by default, since the dependency ordering of worker pools causes terraform to deploy the
  # script before the workers. As such, rollout will always fail. Note that this should be set to true after the first
  # deploy to ensure that terraform waits until rollout of the upgraded components completes before completing the
  # apply.
  default = false
}

# Kubectl configuration options

variable "configure_kubectl" {
  description = "Configure the kubeconfig file so that kubectl can be used to access the deployed EKS cluster."
  type        = bool
  default     = false
}

variable "kubectl_config_path" {
  description = "The path to the configuration file to use for kubectl, if var.configure_kubectl is true. Defaults to ~/.kube/config."
  type        = string

  # The underlying command will use the default path when empty
  default = ""
}

variable "use_kubergrunt_verification" {
  description = "When set to true, this will enable kubergrunt verification to wait for the Kubernetes API server to come up before completing. If false, reverts to a 30 second timed wait instead."
  type        = bool
  default     = false
}

variable "iam_role_to_rbac_group_mappings" {
  description = "Mapping of AWS IAM roles to RBAC groups, where the keys are AWS ARN of IAM roles and values are the mapped k8s RBAC group names as a list."
  type        = map(list(string))
  default     = {}
}

variable "iam_user_to_rbac_group_mappings" {
  description = "Mapping of AWS IAM users to RBAC groups, where the keys are AWS ARN of IAM users and values are the mapped k8s RBAC group names as a list."
  type        = map(list(string))
  default     = {}
}