FROM golang:alpine

ENV TERRAFORM_VERSION=0.12.10
ENV GCP_SDK_VERSION=266.0.0

RUN apk add --update git bash openssh curl python

RUN export SDK_FILENAME=google-cloud-sdk-${GCP_SDK_VERSION}-linux-x86_64.tar.gz && \
  curl -O -J https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${SDK_FILENAME} && \
  tar -zxvf ${SDK_FILENAME} --directory ${HOME} && \
  ln -s ${HOME}/google-cloud-sdk/bin/* /bin

ENV TF_DEV=true
ENV TF_RELEASE=true

WORKDIR $GOPATH/src/github.com/hashicorp/terraform
RUN git clone https://github.com/hashicorp/terraform.git ./ && \
    git checkout v${TERRAFORM_VERSION} && \
    /bin/bash scripts/build.sh

WORKDIR $GOPATH
COPY ./scripts/docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]
