#!/usr/bin/env sh
# Author: Joe Maloney
# License: BSD
# Location for tests into REST API of FreeNAS 9.10

# Where is the ixbuild program installed
PROGDIR="$(dirname "$(realpath "$(dirname "$0")")")"; export PROGDIR

# Source our Testing functions
. ${PROGDIR}/scripts/functions.sh
. ${PROGDIR}/scripts/functions-tests.sh

# Set which python, pip versions to use
PYTHON="/usr/bin/env python3.6"
PIP="/usr/bin/env pip3.6"

# Use venv to avoid needing superuser
$PYTHON -m venv /tmp/py3-venv
. /tmp/py3-venv/bin/activate
 
# Installl modules
$PIP install requests
$PIP install ws4py

#################################################################
# Run the tests now!
#################################################################

echo "Using API Address: http://${FNASTESTIP}/api/v2.0"

git clone https://www.github.com/freenas/freenas --depth=1 /tmp/freenas
cd /tmp/freenas/src/middlewared
$PIP uninstall -y middlewared.client
$PYTHON setup_client.py install --single-version-externally-managed --record $(mktemp)
cd /tmp/freenas/src/middlewared/middlewared/pytest
echo [Target] > target.conf
echo hostname = ${FNASTESTIP} >> target.conf
echo api = /api/v2.0/ >> target.conf
echo username = "root" >> target.conf
echo password = "testing" >> target.conf
sed -i '' "s|'freenas'|'testing'|g" functional/test_0001_authentication.py
$PYTHON -m pytest -sv functional --junitxml=$RESULTSDIR/results.xml.v2.0
TOTALTESTS="14"
publish_pytest_results "$TOTALCOUNT"

exit 0
