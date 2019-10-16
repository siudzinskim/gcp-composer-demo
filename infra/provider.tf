provider "google" {
  project = "${var.project}"
  region  = "${var.region}"
}

data "google_project" "project" {}
data "google_project" "current" {}

data "google_service_account_access_token" "service_token" {
  provider = "google"
  target_service_account = "${var.tf_account}"
  scopes = ["userinfo-email", "cloud-platform"]
  lifetime = "300s"
}

provider "google" {
  alias = "impersonated"
  access_token = "${data.google_service_account_access_token.service_token.access_token}"
  project = "${var.project}"
  region  = "${var.region}"
}

terraform {
  backend "gcs" {
    bucket = "${var.project}-tf-state"
    prefix = "terraform/state"
  }
}