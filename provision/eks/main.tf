# Fetching outputs

data "terraform_remote_state" "vpc" {
  backend = "s3"

  config = {
    bucket = "eks-terraform-anuj"
    key    = "vpc/vpc.tfstate"
    region = "eu-west-1"
  }
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

data "aws_iam_policy" "AmazonEKSWorkerNodePolicy" {
  arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

data "aws_iam_policy" "AmazonEKS_CNI_Policy" {
  arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

data "aws_iam_policy" "AmazonEC2ContainerRegistryReadOnly" {
  arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
  version                = "~> 1.11"
}

module alb-ingress-controller-policy {
  source = "../modules/terraform-module-aws-iam-policy/"

  policy_name        = "alb-ingress-controller-policy"
  policy_description = "Policy for ALB Ingress Controller"
  policy_document    = file("${path.module}/policies/alb-ingress-controller-policy.json")
}

module kube2iam-policy {
  source = "../../modules/terraform-module-aws-iam-policy/"

  policy_name        = "kube2iam-policy"
  policy_description = "Policy for Kube2Iam"
  policy_document    = file("${path.module}/policies/kube2iam-policy.json")
}

module external-dns-policy {
  source = "../../modules/terraform-module-aws-iam-policy/"

  policy_name        = "external-dns-policy"
  policy_description = "Policy for External DNS controller"
  policy_document    = file("${path.module}/policies/external-dns-policy.json")
}

module cluster-autoscalar-policy {
  source = "../../modules/terraform-module-aws-iam-policy/"

  policy_name        = "cluster-autoscalar-policy"
  policy_description = "Policy for External DNS controller"
  policy_document    = file("${path.module}/policies/cluster-autoscalar-policy.json")
}

module cni-metric-helper-policy {
  source = "../../modules/terraform-module-aws-iam-policy/"

  policy_name        = "cni-metric-helper-policy"
  policy_description = "Policy for External DNS controller"
  policy_document    = file("${path.module}/policies/cni-metric-helper-policy.json")
}

module eks_worker_role {
  source = "../../modules/terraform-module-aws-iam-role/"

  iam_role_name        = "eks_worker_role"
  iam_role_description = "Worker role for EKS node"
  assume_role_policy   = file("${path.module}/policies/assume-role-policy.json")
  iam_policy_arns = [module.alb-ingress-controller-policy.policy_arn,
    module.external-dns-policy.policy_arn,
    module.cni-metric-helper-policy.policy_arn,
    module.cluster-autoscalar-policy.policy_arn,
    data.aws_iam_policy.AmazonEKSWorkerNodePolicy.arn,
    module.kube2iam-policy.policy_arn,
    data.aws_iam_policy.AmazonEKS_CNI_Policy.arn,
  data.aws_iam_policy.AmazonEC2ContainerRegistryReadOnly.arn]
}

resource "aws_iam_instance_profile" "eks_worker_instance_profile" {
  name = "eks_worker_instance_profile"
  role = module.eks_worker_role.iam_role_name
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "11.0.0"


  cluster_name                = "test-eks-cluster"
  cluster_version             = "1.15"
  map_users                   = var.map_users
  subnets                     = data.terraform_remote_state.vpc.outputs.private-subnets
  vpc_id                      = data.terraform_remote_state.vpc.outputs.vpc_id
  manage_worker_iam_resources = false

  worker_groups_launch_template = [
    {
      name                      = "spot-fleet-application-components"
      override_instance_types   = ["t3a.medium", "t3.medium",]
      spot_instance_pools       = 2
      asg_min_size              = 1
      asg_max_size              = 2
      asg_desired_capacity      = 1
      kubelet_extra_args        = "--node-labels=kubernetes.io/lifecycle=spot"
      public_ip                 = false
      iam_instance_profile_name = aws_iam_instance_profile.eks_worker_instance_profile.name
      tags                      = local.asg_tags
    },
    {
      name                      = "on-demand-control-plane-components"
      instance_type             = "t3a.medium"
      asg_min_size              = 1
      asg_max_size              = 2
      asg_desired_capacity      = 1
      public_ip                 = false
      kubelet_extra_args        = "--node-labels=kubernetes.io/lifecycle=onDemand"
      iam_instance_profile_name = aws_iam_instance_profile.eks_worker_instance_profile.name
      tags                      = local.asg_tags
    }
  ]

}