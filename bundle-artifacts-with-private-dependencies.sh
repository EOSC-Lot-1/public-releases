#!/bin/bash
set -ue -o pipefail

#set -x

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

_cloneRepo() {
    declare -r repoName=${1}
    declare -r repoTag=${2}
    declare -n outputName=${3}
    outputName="${repoName}-${repoTag//[-.+]/_}"
    [[ ! -d code/${outputName} ]] || return 0
    git clone --depth=1 https://github.com/${githubOwner}/${repoName} code/${outputName}
    (cd code/${outputName} && git fetch --depth=1 origin tag ${repoTag})
}

_archiveRepo() {
    declare -r repoName=${1}
    declare -r repoTag=${2}
    declare -r outputName=${3}
    (cd code/${outputName} && git archive ${repoTag} -o ../${outputName}.zip)    
}

_listPrivateArtifactsForMavenProject() {
    declare -r projectDir=${1}
    [[ -f "${projectDir}/pom.xml" ]] || return 0
    (
        cd ${projectDir}
        ./mvnw dependency:list -DoutputFile=.dependencies.txt -B 1>/dev/null
        grep -Po -e "^[ ]+\K${privateArtifactGroupId//[.]/[.]}:([^:]+):jar:([^:]+):(compile)" .dependencies.txt |\
          gawk -F ':' '{ printf ("%s:%s\n", $2, $4) }'
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

declare repoOutputName=
while true; do
    _dequeue artifactQueue artifactName
    [[ -n "${artifactName}" ]] || break
    [[ -z ${artifactResolved[${artifactName}]:-} ]] || continue
    repoName=${artifactName%:*} repoTag=${artifactName#*:} 
    # Download private repo
    echo " === $artifactName ==="
    _cloneRepo ${repoName} ${repoTag} repoOutputName
    _archiveRepo ${repoName} ${repoTag} ${repoOutputName}
    artifactResolved[${artifactName}]=${artifactName}
    # Fetch private dependencies
    while read dependencyArtifactName; do
        _enqueue artifactQueue ${dependencyArtifactName}
    done < <(_listPrivateArtifactsForMavenProject code/${repoOutputName})
done

zip -j ${outputFile} code/*.zip
