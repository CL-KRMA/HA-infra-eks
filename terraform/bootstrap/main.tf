# ============================================================
# Bootstrap du backend Terraform (bucket S3 + cle KMS)
#
# A appliquer UNE SEULE FOIS, avant le code principal (../).
# Ce module garde volontairement son state en local : il cree
# le bucket qui hebergera le state de tout le reste (poule/oeuf).
# Il est petit et reconstructible (terraform import) si perdu.
#
# Utilisation recommandee : ../../scripts/bootstrap-backend.sh
# ============================================================

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 7.0"
    }
  }
}

variable "region" {
  description = "Region AWS du bucket (la meme que le cluster, idealement)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixe des ressources"
  type        = string
  default     = "eks-cluster"
}

variable "state_key" {
  description = "Chemin du fichier state du code principal dans le bucket"
  type        = string
  default     = "eks/terraform.tfstate"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform-bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # Les noms de bucket S3 sont uniques mondialement -> on ajoute l'ID de compte
  bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}

# --- Cle KMS dediee au chiffrement du state ---
resource "aws_kms_key" "tfstate" {
  description             = "Chiffrement du state Terraform (${var.project_name})"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/${var.project_name}-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

# --- Bucket S3 ---
resource "aws_s3_bucket" "tfstate" {
  bucket        = local.bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

# ACL desactivees : le proprietaire du bucket possede tous les objets
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Versioning : permet de revenir a un state anterieur apres une erreur
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Refuse tout acces non chiffre en transit (HTTP)
data "aws_iam_policy_document" "tfstate" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# Garde l'historique utile sans le laisser grossir indefiniment
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 20
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.tfstate]
}

# --- Sorties : consommees par scripts/bootstrap-backend.sh ---
output "bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "region" {
  value = var.region
}

output "kms_key_arn" {
  value = aws_kms_key.tfstate.arn
}

output "state_key" {
  value = var.state_key
}
