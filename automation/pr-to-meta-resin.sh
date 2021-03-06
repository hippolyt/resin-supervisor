#!/bin/bash
# PR a supervisor release to meta-resin
#
# It clones meta-resin and opens a PR changing the supervisor version to $TAG.
# If a meta-resin folder exists, it assumes it has a meta-resin git repo.
#
# If $PR_1X is "true", an additional PR for 1.X will be created.
#
# Requires ssh keys set up to push and create the pull-request.
# Requires $TAG to be set to the supervisor version to use.
# Requires hub to be installed (see https://github.com/github/hub)
#

set -e

THIS_FILE=$0
if [ -z "$TAG" ]; then
	cat $THIS_FILE | awk '{if(/^#/)print;else exit}' | tail -n +2 | sed 's/\#//'
	exit 1
fi

REPO_URL="git@github.com:resin-os/meta-resin.git"
USER=${USER:-$(whoami)}

function prepareBranches() {
	BASE=$1
	HEAD=$2
	git checkout $BASE
	git reset HEAD
	git checkout .
	git fetch
	git merge origin/${BASE}
	git checkout -b ${HEAD}
}

function setSupervisorTag() {
	sed -i "s/SUPERVISOR_TAG ?= \".*\"/SUPERVISOR_TAG ?= \"${TAG}\"/" meta-resin-common/recipes-containers/docker-disk/docker-resin-supervisor-disk.bb
}

function commitAndPR() {
	BASE=$1
	HEAD=$2
	git commit -as -m "
docker-resin-supervisor-disk: Update to ${TAG}

Changelog-Entry: Update supervisor to ${TAG}
Change-Type: patch
"

	git push origin $HEAD

	hub pull-request -b ${BASE} -m "${BASE}: Update supervisor to ${TAG}

Change-Type: patch
"

}

if [ ! -d "./meta-resin" ]; then
	echo "Cloning meta-resin..."
	git clone $REPO_URL
else
	echo "Using available meta-resin repo"
fi
cd meta-resin

echo "Creating pull request to add supervisor ${TAG} on master"
prepareBranches master supervisor-${TAG}
setSupervisorTag
commitAndPR master supervisor-${TAG}

if [ "$PR_1X" = "true" ]; then
	echo "Creating pull request to add supervisor ${TAG} on 1.X"
	prepareBranches 1.X 1.X-supervisor-${TAG}
	setSupervisorTag	
	commitAndPR 1.X 1.X-supervisor-${TAG}
fi
