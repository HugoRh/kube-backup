FROM alpine:3.12

RUN apk update && \
  apk add --update \
    bash \
    easy-rsa \
    git \
    openssh-client \
    curl \
    ca-certificates \
    jq \
    python3 \
    py-yaml \
    py3-pip \
    libstdc++ \
    gpgme \
    git-crypt \
    && \
  rm -rf /var/cache/apk/*

RUN pip install ijson awscli yq
RUN adduser -h /backup -D backup

ENV KUBECTL_VERSION 1.17.5
ENV KUBECTL_URI https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl

RUN curl -SL ${KUBECTL_URI} -o kubectl && chmod +x kubectl

ENV PATH="/:${PATH}"

COPY entrypoint.sh /
USER backup
ENTRYPOINT ["/entrypoint.sh"]
