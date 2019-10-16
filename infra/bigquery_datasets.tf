resource "google_bigquery_dataset" "bigquery-dataset" {
  dataset_id    = "demo"
  friendly_name = "demo"
  location      = "${var.bq_region}"
  delete_contents_on_destroy = true

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }
  access {
    role   = "READER"
    special_group = "projectWriters"
  }
  access {
    role           = "WRITER"
    special_group = "projectWriters"
  }
}