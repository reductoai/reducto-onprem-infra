terraform {
  backend "s3" {
    bucket = "terraform-states-account-004078808828"
    key    = "reducto"
    region = var.region
  }
}
