# ============================================================
# Versions Terraform / providers
# ============================================================
# Le fichier .terraform.lock.hcl (versionne dans git) fige la version
# EXACTE du provider ; la contrainte ci-dessous n'est qu'un garde-fou.
# aws_eks_pod_identity_association exige un provider AWS >= 5.60.
# Pour monter volontairement de version : terraform init -upgrade,
# puis committer le nouveau .terraform.lock.hcl.
terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 7.0"
    }
  }
}

# ============================================================
# Variables
# ============================================================
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nom du projet (utilise pour les tags)"
  type        = string
  default     = "eks-cluster"
}

variable "cluster_name" {
  description = "Nom du cluster EKS - doit correspondre a cluster_name dans ansible/group_vars/all/vars.yml"
  type        = string
  default     = "eks-cluster"
}

variable "kubernetes_version" {
  description = "Version Kubernetes du control plane EKS. Verifier la fin de support standard : aws eks describe-cluster-versions (au-dela, EKS facture le support etendu)."
  type        = string
  default     = "1.35"
}

variable "allowed_api_cidr" {
  description = "CIDR autorise a joindre l'API Kubernetes publique (kubectl/helm depuis ta machine) - remplace par ton IP : 'x.x.x.x/32'"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "Type d'instance des noeuds du node group"
  type        = string
  default     = "m5.large"
}

variable "node_desired_size" {
  description = "Nombre de noeuds souhaite dans le node group"
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Nombre minimum de noeuds (garder >= az_count pour avoir au moins 1 noeud par AZ)"
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Nombre maximum de noeuds"
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "Taille du disque root en GB pour chaque noeud"
  type        = number
  default     = 50
}

variable "vpc_cidr" {
  description = "CIDR du VPC"
  type        = string
  default     = "192.168.0.0/16"
}

variable "az_count" {
  description = "Nombre de zones de disponibilite (AZ) utilisees : un subnet public et un subnet prive par AZ, noeuds repartis par le node group. EKS exige au moins 2 AZ ; 3 permet de perdre une AZ en gardant 2 noeuds sur 3."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count doit etre compris entre 2 et 6 (EKS exige au moins 2 AZ)."
  }
}

variable "nat_per_az" {
  description = "false = un seul NAT Gateway (economique, lab) ; true = un NAT Gateway par AZ (sortie Internet des noeuds resiliente a la perte d'une AZ, environ +36 $/mois par NAT supplementaire)."
  type        = bool
  default     = false
}

variable "public_subnet_cidrs" {
  description = "CIDR des subnets publics, un par AZ (load balancer + NAT Gateway). Doit contenir az_count elements."
  type        = list(string)
  default     = ["192.168.1.0/24", "192.168.2.0/24", "192.168.5.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == var.az_count
    error_message = "public_subnet_cidrs doit contenir exactement az_count CIDR."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR des subnets prives, un par AZ (noeuds EKS). Doit contenir az_count elements. Les pods consomment des IP du VPC : garder des /24 au minimum."
  type        = list(string)
  default     = ["192.168.3.0/24", "192.168.4.0/24", "192.168.6.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == var.az_count
    error_message = "private_subnet_cidrs doit contenir exactement az_count CIDR."
  }
}

# ============================================================
# Provider
# ============================================================
provider "aws" {
  region = var.region
}

# ============================================================
# Reseau
# ============================================================
# - 1 VPC
# - az_count subnets publics (1 par AZ) : Internet Gateway, NAT
#   Gateway, load balancer (NLB cree par le Service Traefik).
# - az_count subnets prives (1 par AZ) : noeuds EKS.
# - Sortie Internet des noeuds prives :
#     nat_per_az = false -> un seul NAT Gateway (economique) ; une
#                           panne de son AZ coupe la sortie Internet
#                           des noeuds, pas le trafic entrant.
#     nat_per_az = true  -> un NAT Gateway par AZ (chaque AZ a sa
#                           propre sortie).
#
# Les AZ sont lues dynamiquement (data source) : pas de suffixe
# "a"/"b"/"c" code en dur. Le node group repartit lui-meme les noeuds
# sur les subnets prives fournis.
#
# Les tags kubernetes.io/... permettent a Kubernetes de choisir les
# bons subnets pour les load balancers.
data "aws_availability_zones" "available" {
  state = "available"

  # Exclut les Local Zones / Wavelength Zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs       = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  nat_count = var.nat_per_az ? var.az_count : 1
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.project_name}-subnet-public-${substr(local.azs[count.index], -1, 1)}"
    Project                                     = var.project_name
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.project_name}-subnet-private-${substr(local.azs[count.index], -1, 1)}"
    Project                                     = var.project_name
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# --- Table de routage publique (route IGW) ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-rt-public"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- NAT Gateway(s) (sortie Internet des noeuds prives : pull
#     d'images, appels AWS, etc.). 1 seul par defaut, 1 par AZ si
#     nat_per_az = true. Le NAT i vit dans le subnet public de l'AZ i. ---
resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-nat-eip-${substr(local.azs[count.index], -1, 1)}"
    Project = var.project_name
  }
}

resource "aws_nat_gateway" "main" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name    = "${var.project_name}-nat-${substr(local.azs[count.index], -1, 1)}"
    Project = var.project_name
  }

  depends_on = [aws_internet_gateway.main]
}

# --- Tables de routage privees : une par AZ. Chacune pointe vers le
#     NAT de son AZ (nat_per_az = true) ou vers l'unique NAT (false).
#     Passer nat_per_az de false a true ne change que ces routes. ---
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[var.nat_per_az ? count.index : 0].id
  }

  tags = {
    Name    = "${var.project_name}-rt-private-${substr(local.azs[count.index], -1, 1)}"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ============================================================
# IAM - Control plane EKS
# ============================================================
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ============================================================
# Cluster EKS
# ============================================================
# - Control plane gere par AWS (API server + etcd multi-AZ geres
#   par AWS, plus de masters a administrer).
# - Endpoint API public restreint a allowed_api_cidr (kubectl/helm
#   depuis ta machine) + endpoint prive (trafic des noeuds).
# - Le createur du cluster (l'identite AWS qui lance terraform apply)
#   recoit automatiquement les droits admin : c'est la meme identite
#   qu'utilisera ansible via `aws eks update-kubeconfig`.
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids = concat(
      aws_subnet.private[*].id,
      aws_subnet.public[*].id,
    )
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.allowed_api_cidr]
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = {
    Project = var.project_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_route_table_association.private,
  ]
}

# ============================================================
# IAM - Noeuds (node group manage)
# ============================================================
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ============================================================
# Node group manage (noeuds dans les subnets prives)
# ============================================================
# EKS repartit lui-meme les noeuds sur les subnets fournis. Les
# mises a jour d'AMI / de version se font par rolling update.
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = [var.instance_type]
  disk_size      = var.node_disk_size

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Project = var.project_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_nat_gateway.main,
  ]
}

# ============================================================
# Add-on EBS CSI driver (volumes persistants Prometheus/Grafana)
# ============================================================
# Sur EKS, sans ce driver les PVC (EBS) restent en Pending.
# L'acces AWS du driver passe par EKS Pod Identity (pas d'OIDC
# provider a creer).
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  depends_on = [aws_eks_pod_identity_association.ebs_csi]
}

# ============================================================
# Outputs
# ============================================================
output "cluster_name" {
  description = "Nom du cluster EKS"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint de l'API Kubernetes"
  value       = aws_eks_cluster.main.endpoint
}

output "region" {
  description = "Region AWS du cluster"
  value       = var.region
}

output "kubeconfig_command" {
  description = "Commande pour generer un kubeconfig local"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.region}"
}

output "availability_zones" {
  description = "AZ utilisees (1 subnet public + 1 subnet prive par AZ)"
  value       = local.azs
}

output "nat_gateway_count" {
  description = "Nombre de NAT Gateways (1 si nat_per_az = false, sinon az_count)"
  value       = local.nat_count
}

output "vpc_id" {
  description = "ID du VPC (utilise par scripts/destroy.sh pour verifier les load balancers restants)"
  value       = aws_vpc.main.id
}

output "project_name" {
  description = "Nom du projet (tag Project, utilise par scripts/destroy.sh pour la verification finale)"
  value       = var.project_name
}
