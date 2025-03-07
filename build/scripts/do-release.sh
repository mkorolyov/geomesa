#!/usr/bin/env bash

set -e
set -u
set -o pipefail

cd "$(dirname "$0")/../.." || exit

usage() {
  echo "Usage: $(basename "$0") [-h|--help]
where :
  -h| --help Display this help text
" 1>&2
  exit 1
}

if [[ ($# -ne 0) ]]; then
  usage
fi

# reads a property out of the release.properties file generated by mvn release:prepare
# args: name of the property to read
readReleaseProp() {
  grep "^$1=" release.properties | head -n1 | sed "s/$1=//"
}

# reads the main version out of the pom
# args: pom file to read from
readPomVersion() {
  # the indentation only matches the top-level version tag
  grep '^    <version>' "$1" | head -n1 | sed -E 's|.*<version>(.*)</version>.*|\1|'
}

copyReleaseArtifacts() {
  echo "Copying release artifacts"
  while IFS= read -r -d '' file; do
    pushd "$(dirname "$file")" >/dev/null
    gpg --armor --detach-sign "$(basename "$file")"
    sha256sum "$(basename "$file")" > "$(basename "$file").sha256"
    popd >/dev/null
    mv "$file"{,.sha256,.asc} "$RELEASE"
  done < <(find geomesa-* -name '*-bin.tar.gz' -print0)
}

JAVA_VERSION="$(mvn help:evaluate -Dexpression=jdk.version -q -DforceStdout)"
if ! [[ $(java -version 2>&1 | head -n 1 | cut -d'"' -f2) =~ ^$JAVA_VERSION.* ]]; then
  echo "Error: invalid Java version - Java $JAVA_VERSION required"
  exit 1
fi

if ! [[ $(which gpg) ]]; then
  echo "Error: gpg executable not found (required for signed release)"
  exit 1
fi

# get current branch we're releasing off
BRANCH="$(git branch --show-current)"

# use the maven release plugin to prep the pom changes but use dryRun to skip commit and tag
mvn release:prepare \
  -DdryRun=true \
  -DautoVersionSubmodules=true \
  -Darguments="-DskipTests -Dmaven.javadoc.skip=true -Ppython" \
  -Ppython

RELEASE="$(readPomVersion pom.xml.tag)"
TAG="$(readReleaseProp scm.tag)"
NEXT="$(readPomVersion pom.xml.next)"

# update README versions and commit
for pom in pom.xml pom.xml.tag pom.xml.next; do
  sed -i "s|<geomesa\.release\.version>.*|<geomesa.release.version>$RELEASE</geomesa.release.version>|" "$pom"
  sed -i "s|<geomesa\.devel\.version>.*|<geomesa.devel.version>$NEXT</geomesa.devel.version>|" "$pom"
done
# regenerates the README
mvn clean install -pl .
git commit -am "Set version for release $RELEASE"

# commit release tag
find . -name pom.xml -exec mv {}.tag {} \;
git commit -am "[maven-release-plugin] prepare release $TAG"
git tag "$TAG"

# commit next dev version
find . -name pom.xml -exec mv {}.next {} \;
git commit -am "[maven-release-plugin] prepare for next development iteration"

# clean up leftover release artifacts
mvn release:clean

# deploy to maven central
git checkout "$TAG"
mkdir -p "$RELEASE"

mvn clean deploy -Pcentral,python -DskipTests | tee "$RELEASE"/build_2.12.log
copyReleaseArtifacts

./build/scripts/change-scala-version.sh 2.13
mvn clean deploy -Pcentral,python -DskipTests | tee "$RELEASE"/build_2.13.log
copyReleaseArtifacts

# reset pom changes
./build/scripts/change-scala-version.sh 2.12
git restore README.md

# push commits and tags
git checkout "$BRANCH"
git push lt "$BRANCH"
git push lt "$TAG"
