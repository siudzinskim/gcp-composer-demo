import gzip
import json
import logging
from datetime import timedelta
from ftplib import FTP
from io import BytesIO

import airflow
from airflow import models
from airflow.contrib.operators import bigquery_operator, \
    bigquery_table_delete_operator
from airflow.operators import dummy_operator, python_operator, http_operator
from airflow.sensors import http_sensor
from google.cloud import storage

# --------------------------------------------------------------------------------
# Set variables`
# --------------------------------------------------------------------------------

PROJECT_ID = models.Variable.get('PROJECT_ID')
DATAPREP_KEY = models.Variable.get('DATAPREP_KEY')
DATAPREP_WRANGLED_DATASET_ID = models.Variable.get('DATAPREP_WRANGLED_DATASET_ID')
BUCKET_NAME = PROJECT_ID

# --------------------------------------------------------------------------------
# Set default arguments
# --------------------------------------------------------------------------------

default_args = {
    'owner': 'airflow',
    'start_date': airflow.utils.dates.days_ago(1),
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=10),
    'dataflow_default_options': {
        'project': PROJECT_ID,
        'region': 'europe-west1',
    }
}

# --------------------------------------------------------------------------------
# Set GCP logging
# --------------------------------------------------------------------------------

logger = logging.getLogger('ingestor')

# --------------------------------------------------------------------------------
# Functions
# --------------------------------------------------------------------------------
def stream_ftp_to_gsc(host, path):
    gcs = storage.Client()
    bucket = gcs.bucket(BUCKET_NAME)
    ftp = FTP(host=host)
    ftp.login()

    with BytesIO() as remote_file:
        ftp.retrbinary('RETR ' + path, remote_file.write)
        blob = bucket.blob(path.split('/')[-1])
        remote_file.seek(0)
        blob.upload_from_file(remote_file)


def gunzip_to_gcs(file):
    gcs = storage.Client()
    bucket = gcs.bucket(BUCKET_NAME)
    dest_file = file[:-3]
    blob = bucket.blob(file)
    file_content = gzip.decompress(blob.download_as_string())
    new_blob = bucket.blob(dest_file)
    new_blob.upload_from_string(file_content)
    print('Blob {} uncompressed to {}.'.format(file, dest_file))


def get_job_from_xcom(**kwargs):
    job_id = json.loads(kwargs['ti'].xcom_pull(task_ids='start_dataprep'))[
        'id']
    return job_id


# --------------------------------------------------------------------------------
# Main DAG
# --------------------------------------------------------------------------------

dag = models.DAG(
    dag_id='demo_etl',
    default_args=default_args,
    schedule_interval=None
)

start = dummy_operator.DummyOperator(
    task_id='start',
    trigger_rule='all_success',
    dag=dag
)

tables_deleted = dummy_operator.DummyOperator(
    task_id='tables_deleted',
    trigger_rule='all_success',
    dag=dag
)

data_collected = dummy_operator.DummyOperator(
    task_id='data_collected',
    trigger_rule='all_success',
    dag=dag
)

end = dummy_operator.DummyOperator(
    task_id='end',
    trigger_rule='all_success',
    dag=dag
)

delete_jobs = []
for tab in ['taxi_trips', 'taxi_trips_agg']:
    delete_dest_table_if_exist = bigquery_table_delete_operator.BigQueryTableDeleteOperator(
        task_id='delete-dest-table-{}-if-exist'.format(tab),
        deletion_dataset_table="{}.demo.{}".format(PROJECT_ID, tab),
        ignore_if_missing=True,
        dag=dag
    )
    delete_jobs.append(delete_dest_table_if_exist)

get_data_from_nyc_bq = bigquery_operator.BigQueryOperator(
    task_id='get-data-from-nyc-bq',
    sql="""SELECT 
    CAST(pickup_datetime AS DATE) AS pickup_datetime, 
    tip_amount, 
    total_amount
FROM `bigquery-public-data.new_york_taxi_trips.tlc_green_trips_2018` 
""",
    destination_dataset_table="{}.demo.taxi_trips".format(PROJECT_ID),
    time_partitioning={
        "type": "DAY",
        "field": "pickup_datetime",
    },
    use_legacy_sql=False,
    write_disposition='WRITE_TRUNCATE',
    dag=dag
)

aggregate_data_from_nyc_bq = bigquery_operator.BigQueryOperator(
    task_id='aggregate-data-from-nyc-bq',
    sql="""SELECT 
  CAST(pickup_datetime AS DATE) AS trip_date, 
  MIN(tip_amount) AS min_tips, 
  AVG(tip_amount) AS avg_tips, 
  MAX(tip_amount) AS max_tips, 
  SUM(tip_amount) AS sum_tips, 
  MIN(total_amount) AS min_total, 
  AVG(total_amount) AS avg_total, 
  MAX(total_amount) AS max_total, 
  SUM(total_amount) AS sum_total
FROM `bigquery-public-data.new_york_taxi_trips.tlc_green_trips_2018` 
WHERE CAST(pickup_datetime AS DATE) BETWEEN DATE(2018, 1, 1) AND DATE(2018, 12,31)
GROUP BY CAST(pickup_datetime AS DATE)""",
    destination_dataset_table="{}.demo.taxi_trips_agg".format(PROJECT_ID),
    time_partitioning={
        "type": "DAY",
        "field": "trip_date",
    },
    use_legacy_sql=False,
    write_disposition='WRITE_TRUNCATE',
    dag=dag
)

get_raw_weather_data = python_operator.PythonOperator(
    task_id='get-raw-weather-data',
    python_callable=stream_ftp_to_gsc,
    op_kwargs={'host': 'ftp.ncdc.noaa.gov',
               'path': '/pub/data/noaa/2018/725053-94728-2018.gz'},
    dag=dag
)

uncompress_weather_data = python_operator.PythonOperator(
    task_id='uncompress-weather-data',
    python_callable=gunzip_to_gcs,
    op_kwargs={'file': '725053-94728-2018.gz'},
    dag=dag
)

start_dataprep = http_operator.SimpleHttpOperator(
    task_id='start_dataprep',
    method='POST',
    http_conn_id='cloud_dataprep',
    endpoint='/v4/jobGroups/',
    headers={
        'Authorization': 'Bearer {}'.format(DATAPREP_KEY),
        'content-type': 'application/json'
    },
    data='{"wrangledDataset": {"id":'+DATAPREP_WRANGLED_DATASET_ID+'}}',
    xcom_push=True,
    log_response=True,
    dag=dag
)


get_dataprep_job_id = python_operator.PythonOperator(
    task_id='get_dataprep_job_id',
    python_callable=get_job_from_xcom,
    provide_context=True,
    dag=dag
)

get_dataprep_job_status = http_sensor.HttpSensor(
    task_id='get_dataprep_job_status',
    http_conn_id='cloud_dataprep',
    endpoint='/v4/jobGroups/{{ task_instance.xcom_pull(task_ids="get_dataprep_job_id") }}',
    headers={
        'Authorization': 'Bearer {}'.format(DATAPREP_KEY),
        'content-type': 'application/json'
    },
    response_check=lambda resp: True if resp.json()['status'] == 'Complete' else False,
    dag=dag
)

start >> delete_jobs >> tables_deleted >> [get_data_from_nyc_bq, aggregate_data_from_nyc_bq] >> data_collected
start >> get_raw_weather_data >> uncompress_weather_data >> start_dataprep >> get_dataprep_job_id >> get_dataprep_job_status >> data_collected
data_collected >> end