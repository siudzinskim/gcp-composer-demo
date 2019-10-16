ACTIVE_ACCOUNT=`gcloud config list account --format "value(core.account)"`
ifndef TF_MODULE
	TF_MODULE=infra
endif

docker-image = gcp_composer_demo/terraform

docker-run = docker run -i -t -v ~/.config/gcloud/:/root/.config/gcloud/ \
	-v ${PWD}:/app/ \
	-v ${HOME}/.config/gcloud/:/app/.config/gcloud \
	-w /app/

ifdef CLOUDSDK_ACTIVE_CONFIG_NAME
	docker-run += -e CLOUDSDK_ACTIVE_CONFIG_NAME=${CLOUDSDK_ACTIVE_CONFIG_NAME}
endif
ifdef TF_VAR_project
	docker-run += -e TF_VAR_project=${TF_VAR_project}
endif
ifdef TF_ACCOUNT
	docker-run += -e TF_VAR_tf_account=${TF_ACCOUNT}
endif
ifdef TF_VAR_region
	docker-run += -e TF_VAR_region=${TF_VAR_region}
endif
ifdef TF_VAR_bq_region
	docker-run += -e TF_VAR_bq_region=${TF_VAR_bq_region}
endif

docker-run += ${docker-image}

show-docker-command:
	echo ${docker-run}

version:
	@echo `cat VERSION`

build-docker:
	docker build -t ${docker-image} .

environment:
	gcloud config configurations create ${TF_VAR_project} || gcloud config configurations describe ${TF_VAR_project}
	gcloud config set project ${TF_VAR_project}
	gcloud auth application-default login
	gcloud auth login

activate:
	gcloud config configurations activate ${TF_VAR_project}

iam:
	gcloud iam service-accounts create terraform --display-name "Terraform admin account" || gcloud iam service-accounts describe terraform@${TF_VAR_project}.iam.gserviceaccount.com
	gcloud projects add-iam-policy-binding ${TF_VAR_project} --role=roles/iam.serviceAccountTokenCreator --member=user:${ACTIVE_ACCOUNT}

roles = roles/viewer \
roles/storage.admin \
roles/resourcemanager.projectIamAdmin \
#roles/cloudkms.admin \
roles/iam.roleAdmin \
#roles/iam.serviceAccountKeyAdmin \
#roles/iam.serviceAccountAdmin \
roles/bigquery.admin \
#roles/cloudfunctions.developer \
#roles/cloudbuild.builds.editor \
#roles/cloudscheduler.admin \
#roles/pubsub.admin

policies:
	for role in  $(roles); do \
		gcloud projects add-iam-policy-binding ${TF_VAR_project} \
			--member serviceAccount:${TF_ACCOUNT} \
			--role $$role; \
	done

apis:
	gcloud services enable iam.googleapis.com
#	gcloud services enable cloudkms.googleapis.com
	gcloud services enable cloudresourcemanager.googleapis.com
	gcloud services enable deploymentmanager.googleapis.com
	gcloud services enable bigquery-json.googleapis.com
#	gcloud services enable compute.googleapis.com
#	gcloud services enable cloudfunctions.googleapis.com
	gcloud services enable storage-api.googleapis.com
	gcloud services enable storage-component.googleapis.com
	gcloud services enable logging.googleapis.com
#	gcloud services enable cloudbuild.googleapis.com
#	gcloud services enable cloudscheduler.googleapis.com
#	gcloud services enable appengine.googleapis.com
	gcloud services enable dataflow.googleapis.com
	gcloud services enable composer.googleapis.com
	gcloud services enable sourcerepo.googleapis.com
#	gcloud app create --region=${TF_VAR_apps_region} || gcloud app services list

vpc:
	gcloud compute networks create default || gcloud compute networks describe default

tfstate-bucket:
	gsutil mb -p ${TF_VAR_project} -l ${TF_VAR_region} gs://${TF_VAR_project}-tf-state || gsutil ls gs://${TF_VAR_project}-tf-state
	gsutil versioning set on gs://${TF_VAR_project}-tf-state

terraform-init: tfstate-bucket
#	rm -rf .terraform
#	mkdir .terraform
#	chmod ug+s .terraform
	$(docker-run) init \
	-backend-config="bucket=${TF_VAR_project}-tf-state" \
	${TF_MODULE}

terraform-plan:
	$(docker-run) plan ${TF_MODULE}

terraform-apply: tfstate-bucket
	$(docker-run) apply ${TF_MODULE}

terraform-refresh:
	$(docker-run) refresh ${TF_MODULE}

terraform-apply-force: tfstate-bucket
	$(docker-run) apply -auto-approve ${TF_MODULE}

terraform-destroy: tfstate-bucket
	$(docker-run) destroy ${TF_MODULE}

terraform-validate:
	$(docker-run) validate ${TF_MODULE}

bootstrap: build-docker environment activate iam policies apis vpc tfstate-bucket terraform-init

authenticate:
	gcloud auth application-default login

dags-push:
	gcloud composer environments storage dags import --location=europe-west2 --environment=composer-demo --source=dags/etl.py

create-datalab:
	datalab create lab01

connect-datalab:
	datalab connect lab01