#!/bin/bash -e

if [ -z "$NAMESPACES" ]; then
    NAMESPACES=$(kubectl get ns -o=custom-columns=NAME:.metadata.name --no-headers|grep -Ev "default|kube-node-lease|kube-public")
fi

RESOURCETYPES="${RESOURCETYPES:-"ingress deployment configmap svc rc ds networkpolicy statefulset cronjob pvc"}"
GLOBALRESOURCES="${GLOBALRESOURCES:-"namespace storageclass clusterrole clusterrolebinding customresourcedefinition"}"

# Initialize git repo
[ -z "$DRY_RUN" ] && [ -z "$GIT_REPO" ] && echo "Need to define GIT_REPO environment variable" && exit 1
GIT_REPO_PATH="${GIT_REPO_PATH:-"/backup/git"}"
GIT_PREFIX_PATH="${GIT_PREFIX_PATH:-"."}"
GIT_USERNAME="${GIT_USERNAME:-"kube-backup"}"
GIT_EMAIL="${GIT_EMAIL:-"kube-backup@example.com"}"
GIT_BRANCH="${GIT_BRANCH:-"master"}"
GITCRYPT_ENABLE="${GITCRYPT_ENABLE:-"false"}"
GITCRYPT_PRIVATE_KEY="${GITCRYPT_PRIVATE_KEY:-"/secrets/gpg-private.key"}"
GITCRYPT_SYMMETRIC_KEY="${GITCRYPT_SYMMETRIC_KEY:-"/secrets/symmetric.key"}"

if [[ ! -f /backup/.ssh/id_rsa ]]; then
    git config --global credential.helper '!aws codecommit credential-helper $@'
    git config --global credential.UseHttpPath true
fi
[ -z "$DRY_RUN" ] && git config --global user.name "$GIT_USERNAME"
[ -z "$DRY_RUN" ] && git config --global user.email "$GIT_EMAIL"

[ -z "$DRY_RUN" ] && (test -d "$GIT_REPO_PATH" || git clone --depth 1 "$GIT_REPO" "$GIT_REPO_PATH" --branch "$GIT_BRANCH" || git clone "$GIT_REPO" "$GIT_REPO_PATH")
cd "$GIT_REPO_PATH"
[ -z "$DRY_RUN" ] && (git checkout "${GIT_BRANCH}" || git checkout -b "${GIT_BRANCH}")

mkdir -p "$GIT_REPO_PATH/$GIT_PREFIX_PATH"
cd "$GIT_REPO_PATH/$GIT_PREFIX_PATH"

if [ "$GITCRYPT_ENABLE" = "true" ]; then
    if [ -f "$GITCRYPT_PRIVATE_KEY" ]; then
        gpg --allow-secret-key-import --import "$GITCRYPT_PRIVATE_KEY"
        git-crypt unlock
    elif [ -f "$GITCRYPT_SYMMETRIC_KEY" ]; then
        git-crypt unlock "$GITCRYPT_SYMMETRIC_KEY"
    else
        echo "[ERROR] Please verify your env variables (GITCRYPT_PRIVATE_KEY or GITCRYPT_SYMMETRIC_KEY)"
        exit 1
    fi
fi

[ -z "$DRY_RUN" ] && git rm -r '*.yaml' --ignore-unmatch -f

# Start kubernetes state export
for resource in $GLOBALRESOURCES; do
  [ -d "$GIT_REPO_PATH/$GIT_PREFIX_PATH" ] || mkdir -p "$GIT_REPO_PATH/$GIT_PREFIX_PATH"
  echo "Exporting resource: ${resource}" >/dev/stderr
  parm=""
  extradel='yq -SY .'
  case $resource in
    no)
      extradel="yq -SY 'del(.metadata.annotations,.spec.podCIDR,.spec.podCIDRs)'|sed '/^\s\s\s\sbeta.kubernetes.io/d;/^\s\s\s\skubernetes.io/d;/^spec:\s{}/d'"
      ;;
    ns)
      parm='--field-selector metadata.name!=kube-node-lease,metadata.name!=kube-system,metadata.name!=kube-public,metadata.name!=default'
      extradel="yq -SY 'del(.spec)'"
      ;;
    pv)
      extradel="yq -SY 'del(.spec.claimRef)'"
      ;;
  esac
  for i in $(eval kubectl get $resource $parm -o=custom-columns=NAME:.metadata.name --no-headers);do
    eval kubectl get $resource $i -oyaml|yq -SY 'del(
    .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
    .metadata.annotations."pv.kubernetes.io/bound-by-controller",
    .metadata.creationTimestamp,
    .metadata.finalizers,
    .metadata.generation,
    .metadata.resourceVersion,
    .metadata.selfLink,
    .metadata.uid,
    .status)'|eval $extradel |sed '/^\s\sannotations: {}/d' >> $GIT_REPO_PATH/$GIT_PREFIX_PATH/${resource}.yaml && echo --- >> $GIT_REPO_PATH/$GIT_PREFIX_PATH/${resource}.yaml
   done && [ -f $GIT_REPO_PATH/$GIT_PREFIX_PATH/${resource}.yaml ] && sed -i '$ d' $GIT_REPO_PATH/$GIT_PREFIX_PATH/${resource}.yaml
done

for namespace in $NAMESPACES; do
  [ -d "$GIT_REPO_PATH/$GIT_PREFIX_PATH/${namespace}" ] || mkdir -p "$GIT_REPO_PATH/$GIT_PREFIX_PATH/${namespace}"
  for type in $RESOURCETYPES; do
    echo "[${namespace}] Exporting resources: ${type}" >/dev/stderr
    parm=""
    extradel='yq -SY .'
    case $type in
      cm)
        parm="-l OWNER!=TILLER"
        ;;
      sa)
        parm='--field-selector metadata.name!=default'
        extradel="yq -SY 'del(.secrets)'"
        ;;
      secrets)
        parm='--field-selector type!="kubernetes.io/service-account-token",type!="helm.sh/release.v1"'
        extradel="yq -SY 'del(.metadata.ownerReferences)'"
        ;;
    esac
    for name in $(eval kubectl -n $namespace get $type $parm -o=custom-columns=NAME:.metadata.name --no-headers);do
      eval kubectl -n $namespace get $type $name -oyaml|yq -SY 'del(
      .metadata.annotations."autoscaling.alpha.kubernetes.io/conditions",
      .metadata.annotations."autoscaling.alpha.kubernetes.io/current-metrics",
      .metadata.annotations."deployment.kubernetes.io/revision",
      .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
      .metadata.annotations."pv.kubernetes.io/bind-completed",
      .metadata.annotations."pv.kubernetes.io/bound-by-controller",
      .metadata.creationTimestamp,
      .metadata.finalizers,
      .metadata.generation,
      .metadata.resourceVersion,
      .metadata.selfLink,
      .metadata.uid,
      .spec.clusterIP,
      .status)'|eval $extradel |sed '/^\s\sannotations: {}/d' >"$GIT_REPO_PATH/$GIT_PREFIX_PATH/${namespace}/${name}.${type}.yaml"
    done
  done
done

[ -z "$DRY_RUN" ] || exit

cd "${GIT_REPO_PATH}"
date > date.txt
git add .

if ! git diff-index --quiet HEAD --; then
    git commit -m "Automatic backup at $(date)"
    git push origin "${GIT_BRANCH}"
else
    echo "No change"
fi

