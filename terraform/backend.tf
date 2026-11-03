# Backend distant S3 (configuration partielle).
#
# Les valeurs propres a ton compte (bucket, region, cle KMS) ne sont pas
# ecrites ici : elles viennent de backend.hcl, genere par
# scripts/bootstrap-backend.sh (modele : backend.hcl.example).
#
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
