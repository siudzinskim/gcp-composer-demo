resource "google_storage_bucket" "storage-bucket" {
  name = "${var.project}"
  location = "${var.region}"
  force_destroy = true
}

resource "google_composer_environment" "composer-demo" {
  name = "composer-demo"
  region = "europe-west2"
  config {
    node_count = 3
    software_config {
      image_version = "composer-1.7.9-airflow-1.10.2"
      python_version = 3
      env_variables = {
        PROJECT_ID = "${var.project}",
        DATAPREP_KEY = "xyz"
        DATAPREP_WRANGLED_DATASET_ID = 0

      }
    }
  }
}

