#!/bin/bash
set -ue -o pipefail

#set -x

declare -r scriptName=$(basename "${BASH_SOURCE[0]}")

declare -r githubRef=${GITHUB_REF_NAME}
declare -r githubOwner=${GITHUB_REPOSITORY_OWNER}

declare -r outputFile=release-bundle.zip

declare -r privateArtifactGroupId="gr.athenarc.eosc"

declare -a artifactQueue
declare -A artifactResolved

_queue_init() {
  declare -n q=${1}
  q[0]=1 # init head  
}

_enqueue() {
  declare -n q=${1}
  q+=("${2}")
}

_dequeue() {
  declare -n q=${1}
  declare -n item=${2}
  local head=${q[0]}
  item=${q[${head}]:-}
  [[ -z "${item}" ]] || q[0]=$((head + 1))
}

_checkoutRepo() {
    declare -r repoName=${1}
    declare -r repoTag=${2}
    declare -r outputName=${3}
    [[ ! -d code/${outputName} ]] || return 0
    git clone -q --depth=1 https://github.com/${githubOwner}/${repoName} code/${outputName}
    (
        cd code/${outputName}
        git fetch -q --depth=1 origin tag ${repoTag}
        git checkout -q ${repoTag}
    )
}

_archiveRepo() {
    declare -r repoName=${1}
    declare -r repoTag=${2}
    declare -r outputName=${3}
    (cd code/${outputName} && git archive ${repoTag} -o ../${outputName}.zip)    
}

_listPrivateArtifactsForMavenProject() {
    declare -r projectDir=${1}
    local artifactIdPattern="^[ ]+${privateArtifactGroupId//[.]/[.]}:([^:]+):jar:([^:]+):(compile)"
    [[ -f "${projectDir}/pom.xml" ]] || return 0
    (
        cd ${projectDir}
        mvnDependencyListOutputFile=.mvn-dependency-list.out.log
        if ! mvn dependency:list -DoutputFile=.dependencies.txt -B &>${mvnDependencyListOutputFile}; then
            logger -s -t "${scriptName}" -p local7.warning \
              '`mvn dependency:list` returned with a non-zero code: '"${projectDir}"
        fi
        if [[ -f .dependencies.txt ]]; then
            gawk -v pat="${artifactIdPattern}" '$0 ~ pat { print $1 }' .dependencies.txt |\
              gawk -F ':' '{ printf ("%s:%s\n", $2, $4) }'
        else
            logger -s -t "${scriptName}" -p local7.error \
              "Failed to list dependencies of Maven project: ${projectDir}"
        fi
    )
}
    
mkdir -vp code

declare repoName=
declare repoTag=
declare artifactName=

_queue_init artifactQueue
while read repoName repoTag
do
   artifactName="${repoName}:${repoTag}"
   _enqueue artifactQueue ${artifactName}
done < <(jq -r --arg ref "${githubRef}" '.[$ref] | keys[] as $k | "\($k) \(.[$k])"' bundle.json)

declare repoFullName=
while true; do
    _dequeue artifactQueue artifactName
    [[ -n "${artifactName}" ]] || break
    [[ -z ${artifactResolved[${artifactName}]:-} ]] || continue
    repoName=${artifactName%:*} 
    repoTag=${artifactName#*:} 
    repoFullName="${repoName}-${repoTag//[-.+]/_}"
    # Checkout private repo
    logger -s -t "${scriptName}" -p local7.info "Processing artifact [${artifactName}]"
    _checkoutRepo ${repoName} ${repoTag} ${repoFullName}
    _archiveRepo ${repoName} ${repoTag} ${repoFullName}
    artifactResolved[${artifactName}]=${artifactName}
    # Enqueue private dependencies
    _listPrivateArtifactsForMavenProject code/${repoFullName} >/tmp/${repoFullName}-private-artifacts
    while read dependencyArtifactName; do
        _enqueue artifactQueue ${dependencyArtifactName}
    done < /tmp/${repoFullName}-private-artifacts
done

zip -j ${outputFile} code/*.zip
