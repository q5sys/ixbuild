#!/usr/bin/env bash

# Where is the pcbsd-build program installed
PROGDIR="`realpath | sed 's|/scripts||g'`" ; export PROGDIR

# Source the config file
. ${PROGDIR}/freenas.cfg

cd ${PROGDIR}/scripts

# Source our functions
. ${PROGDIR}/scripts/functions.sh
. ${PROGDIR}/scripts/functions-tests.sh

# Look through the output log and try to determine the failure
parse_checkout_error()
{
  ### TODO - Add error detection of checkout failures
  echo '' > ${LOUT}
}

# Look through the output log and try to determine the failure
parse_build_error()
{
  echo '' > ${LOUT}
  export TESTSTDERR=${LOUT}

  # Look for some of the common error messages

  # port failed to compile
  grep -q "ERROR: Packages installation failed" ${1}
  if [ $? -eq 0 ] ; then
    grep "====>> Failed" ${1} >> ${LOUT}
    grep "====>> Skipped" ${1} >> ${LOUT}
    grep "====>> Ignored" ${1} >> ${LOUT}
    return 0
  fi

  ### TODO - Add various error detection as they occur

  # Look for generic error
  grep -q "^ERROR: " ${1}
  if [ $? -eq 0 ] ; then
    # Use the search function to get some context
    ${PROGDIR}/../utils/search -s5 "ERROR: " ${1} >>${LOUT}
    return 0
  fi
}

clean_src_repos()
{

  # Clean out source repos which tend to get cranky on force-push
  cRepos="webui freenas samba ports iocage os py-licenselib py-bsd py-libzfs freenas-pkgtools freenas-docs truenas mdnsresponder netatalk"
  for r in $cRepos
  do
    if [ -d "${PROFILE}/_BE/${r}" ] ; then
      rm -rf ${PROFILE}/_BE/${r}
    fi
  done
}

check_pr_profile()
{
  if [ -z "$ghprbPullLongDescription" ] ; then return 0; fi

  # Are there PROFILE knobs listed
  echo "$ghprbPullLongDescription" | grep -q "PROFILE:"
  if [ $? -ne 0 ] ; then return 0; fi

  local _profile=`echo $ghprbPullLongDescription | sed -n -e 's/^.*PROFILE: //p' | cut -d '\' -f 1`
  echo "*** Found PR PROFILE: $_profile ***"

  BUILDOPTS="PROFILE=${_profile}"
}

# Parse the Pull Description and bring in any other things marked as depends
check_pr_depends()
{
  if [ -z "$ghprbPullLongDescription" ] ; then return 0; fi

  echo "PRDESC: $ghprbPullLongDescription"

  # Are there DEPENDS listed?
  echo "$ghprbPullLongDescription" | grep -q "DEPENDS:"
  if [ $? -ne 0 ] ; then return 0; fi

  echo -e "$ghprbPullLongDescription" > /tmp/.depsParse.$$
  while read line
  do
    echo $line | grep -q "DEPENDS:"
    if [ $? -ne 0 ] ; then continue; fi
    _depsLine=`echo $line | sed -n -e 's/^.*DEPENDS: //p' | cut -d '\' -f 1`
    echo "*** Found PR DEPENDS Line: $_depsLine ***"
    _deps="$_deps $_depsLine"
  done < /tmp/.depsParse.$$
  rm /tmp/.depsParse.$$


  for prtgt in $_deps
  do
     if [ -z "$prtgt" ] ; then continue ; fi
     if [ "$prtgt" = " " ] ; then continue ; fi
     echo "*** Found PR DEPENDS: $_prtgt ***"
     # Pull the target PR/Repo
     tgt=`echo $prtgt | sed 's|http://||g'`
     tgt=`echo $tgt | sed 's|https://||g'`
     tgt=`echo $tgt | sed 's|www.github.com||g'`
     tgt=`echo $tgt | sed 's|github.com||g'`
     tgt=`echo $tgt | sed 's|^/||g'`
     tproject=`echo $tgt | cut -d '/' -f 1`
     trepo=`echo $tgt | cut -d '/' -f 2`
     tbranch=`echo $tgt | cut -d '/' -f 3-`
     tbranch=`echo $tbranch | sed 's|^tree/||g'`

     if [ -d "${PROFILE}/_BE/${trepo}" ] ; then
       rm -rf ${PROFILE}/_BE/${trepo}
     else
       echo "*** Warning, no such git repo currently checked out: $trepo***"
     fi

     echo "*** Cloning DEPENDS repo https://github.com/$tproject/$trepo $tbranch***"
     git clone --depth=1 -b ${tbranch} https://github.com/${tproject}/${trepo} ${PROFILE}/_BE/${trepo} 2>/tmp/.ghClone.$$ >/tmp/.ghClone.$$
     if [ $? -ne 0 ] ; then
	cat /tmp/.ghClone.$$
	rm /tmp/.ghClone.$$
	echo "**** ERROR: Failed to clone the repo https://github.com/$tproject/$trepo -b $tbranch****"
	exit 1
     fi
     rm /tmp/.ghClone.$$
  done
}

# Allowed settings for BUILDINCREMENTAL
case $BUILDINCREMENTAL in
   ON|on|YES|yes|true|TRUE) BUILDINCREMENTAL="true" ;;
   *) BUILDINCREMENTAL="false" ;;
esac

# Set local location of FreeNAS build
if [ -n "$BUILDTAG" ] ; then
  FNASBDIR="/$BUILDTAG"
else
  FNASBDIR="/freenas"
fi
export FNASBDIR

# Error output log
LOUT="/tmp/fnas-error-debug.txt"
touch ${LOUT}

get_bedir

# Allow these defaults to be overridden
TMPFSWORK="all"
BCONF="/usr/local/etc/poudriere-builders.conf"
if [ -e "$BCONF" ] ; then
  grep -q "^FNBUILDERS=" ${BCONF}
  if [ $? -eq 0 ] ; then
    POUDRIERE_JOBS=$(grep "^FNBUILDERS=" ${BCONF} | cut -d '=' -f 2)
    echo "Setting POUDRIERE_JOBS=$POUDRIERE_JOBS"
    export POUDRIERE_JOBS
    export BUILDWORLD_JOBS="20"
  else
    CPUS=$(sysctl -n kern.smp.cpus)
    if [ $CPUS -gt 8 ] ; then
      echo "Setting POUDRIERE_JOBS=8"
      export POUDRIERE_JOBS="8"
      export BUILDWORLD_JOBS="20"
    fi
  fi
  grep -q "^TMPFSWORK=" ${BCONF}
  if [ $? -eq 0 ] ; then
    TMPFSWORK=$(grep "^TMPFSWORK=" ${BCONF} | cut -d '=' -f 2)
  fi
else
  # Some tuning for our big build boxes
  CPUS=$(sysctl -n kern.smp.cpus)
  if [ $CPUS -gt 8 ] ; then
    echo "Setting POUDRIERE_JOBS=8"
    export POUDRIERE_JOBS="8"
    export BUILDWORLD_JOBS="20"
  fi
fi

# Check if we are building with an alt profile
check_pr_profile

# Cleanup any hanging mounts left over from prior crashed builds
_hMounts=$(mount | grep "on ${FNASBDIR}/")
if [ -n "$_hMounts" ] ; then
  echo "Cleaning hanging mounts: $_hMounts"
  mount | grep "on ${FNASBDIR}/" | awk '{print $1}' | xargs umount -f
fi

# Rotate an old build
if [ -d "${FNASBDIR}" -a "${BUILDINCREMENTAL}" != "true" ] ; then
  echo "Doing fresh build!"
  cd ${FNASBDIR}
  chflags -R 0 ${BEDIR}
  rm -rf ${BEDIR}
fi

# If this is a github pull request builder, check if branch needs to be overridden
if [ -n "$ghprbTargetBranch" ] ; then
  GITFNASBRANCH="$ghprbTargetBranch"
  if [ "$GITFNASBRANCH" = "freenas/master" -a "$PRBUILDER" = "os" ] ; then
    # When building PRs for the "os" repo on freenas/master branch, use right PROFILE
    echo "*** Building with PROFILE=fn_head ***"
    BUILDOPTS="PROFILE=fn_head"
    PROFILEARGS="PROFILE=fn_head"
  fi
  if [ "$GITFNASBRANCH" = "freenas/master" ] ; then
    # Because freenas/master in some branches aligns to master branch of build
    GITFNASBRANCH="master"
  fi
  if [ "$GITFNASBRANCH" = "freenas/11-stable" -a "$PRBUILDER" = "os" ] ; then
    # Because freenas/master in some branches aligns to master branch of build
    GITFNASBRANCH="master"
  fi
  echo "$GITFNASBRANCH" | grep -q "^truenas/"
  if [ $? -eq 0 ] ; then
    # truenas/ -> freenas/
    GITFNASBRANCH="$(echo $GITFNASBRANCH | sed 's|truenas/|freenas/|g')"
  fi
  echo "*** Building GitHub PR, using builder branch: $GITFNASBRANCH ***"
  newTrain="PR-${PRBUILDER}-`echo $ghprbSourceBranch | sed 's|/|-|g'`"
  echo "*** Setting new TRAIN=$newTrain ***"
  BUILDOPTS="$BUILDOPTS TRAIN=$newTrain"
  rm -rf "${WORKSPACE}/artifacts"
fi

if [ "$BUILDINCREMENTAL" = "true" ] ; then
  echo "Doing incremental build!"
  if [ -d "${FNASBDIR}" ] ; then
    cd ${FNASBDIR}
    # Nuke old ISO's / builds
    echo "Removing old build ISOs"
    rm -rf ${BEDIR}/release 2>/dev/null
  fi
fi

# Figure out the flavor for this test
echo $BUILDTAG | grep -q "truenas"
if [ $? -eq 0 ] ; then
  FLAVOR="TRUENAS"
else
  FLAVOR="FREENAS"
fi

# Add JENKINSBUILDSENV to one specified by the build itself
if [ -n "$JENKINSBUILDSENV" ] ; then
  BUILDSENV="$BUILDSENV $JENKINSBUILDSENV"
fi

# Throw env command on the front
if [ -n "$BUILDSENV" ] ; then
  BUILDSENV="env $BUILDSENV"
fi

if [ -n "$PRBUILDER" ] ; then
  # Nuke the build dir if doing Pull Request Build
  echo "*** Cleaning old PR build directory ***"
  cd ${PROGDIR}
  mount | grep "on ${FNASBDIR}/" | awk '{print $3}' | xargs umount -f
  rm -rf ${FNASBDIR} 2>/dev/null
  mount | grep "on ${FNASBDIR}/" | awk '{print $3}' | xargs umount -f
  chflags -R noschg ${FNASBDIR} 2>/dev/null
  mount | grep "on ${FNASBDIR}/" | awk '{print $3}' | xargs umount -f
  rm -rf ${FNASBDIR} 2>/dev/null
  if [ -d "${FNASBDIR}" ] ; then
     echo "ERROR: Failed to cleanup ${FNASBDIR}"
     exit 1
  fi

  if [ "$PRBUILDER" = "build" ] ; then
    # PR Build
    echo "*** Doing PR build of the build/ repo ***"
    echo "${WORKSPACE} -> ${FNASBDIR}"
    mkdir "${FNASBDIR}"
    tar cf - -C "${WORKSPACE}" . | tar xf - -C "${FNASBDIR}"
    if [ $? -ne 0 ] ; then exit_clean; fi
  else
    # Make sure we have our freenas build sources updated
    if [ -d "${FNASBDIR}" ]; then
      git_fnas_up "${FNASBDIR}"
    else
      rc_halt "git clone --depth=1 -b ${GITFNASBRANCH} ${GITFNASURL} ${FNASBDIR}"
    fi
  fi
else
  if [ -d "${FNASBDIR}" ]; then
    git_fnas_up "${FNASBDIR}"
  else
    rc_halt "git clone --depth=1 -b ${GITFNASBRANCH} ${GITFNASURL} ${FNASBDIR}"
  fi
fi
rc_halt "ln -fs ${FNASBDIR} ${FNASSRC}"

# Lets keep our distfiles around and use previous ones
if [ ! -d "/usr/ports/distfiles" ] ; then
  mkdir -p /usr/ports/distfiles
fi
if [ -e "${FNASSRC}/build/config/env.pyd" ] ; then
  # FreeNAS 9.10 / 10
  sed -i '' 's|${OBJDIR}/ports/distfiles|/usr/ports/distfiles|g' ${FNASSRC}/build/config/env.pyd
else
  # FreeNAS / TrueNAS 9
  export PORTS_DISTFILES_CACHE="/usr/ports/distfiles"
fi

# Now create the world / kernel / distribution
cd ${FNASSRC}

# Check if we have optional build options
if [ -n "$BUILDOPTS" ] ; then
  BUILDOPTS=`echo $BUILDOPTS | sed "s|%BUILDID%|${BUILD_ID}|g"`
  PROFILEARGS="$PROFILEARGS $BUILDOPTS"

  # Unset so we don't conflict with anything
  export OLDBUILDOPTS="$BUILDOPTS"
  unset BUILDOPTS
fi

echo $PROFILEARGS | grep -q "PRODUCTION=yes"
if [ $? -eq 0 ] ; then
  # PRODUCTION is enabled, make sure VERSION was specified
  if [ -z "$JENKINSVERSION" ] ; then
    echo "PRODUCTION=yes is SET, but no JENKINSVERSION= is set!"
    exit 1
  fi
  PROFILEARGS="${PROFILEARGS} VERSION=$JENKINSVERSION"

  # Cleanup before the build if doing PRODUCTION and INCREMENTAL is set
  if [ "$BUILDINCREMENTAL" != "true" ] ; then
    echo "Running cleandist"
    make cleandist
  fi
fi

# Are we building docs / API?
if [ "$1" = "docs" -o "$1" = "api-docs" ] ; then
  echo "Creating $1"
  cd ${FNASBDIR}
  rc_halt "make checkout $PROFILEARGS"
  rc_halt "make clean-docs $PROFILEARGS"
  rc_halt "make $1 $PROFILEARGS"
  exit 0
fi

# If we have the saved objects from a previous PR build run
# lets extract those to do an INCREMENTAL build and save
# some time
if [ -n "$PRBUILDER" -a -n "${GH_REPO}" ] ; then
  TGBRANCH=$(echo ${ghprbTargetBranch} | sed 's|/|-|g')
  if [ -e "/pr-objs/objs-${GH_REPO}-${TGBRANCH}" ] ; then
    cd ${FNASBDIR}
    BELOC=$(cat /pr-objs/objs-${GH_REPO}-${TGBRANCH}/belocation)
    BELOC=$(dirname $BELOC)
    if [ -n "$BELOC" ] ; then
      mkdir -p ${BELOC} 2>/dev/null
      echo "*** Using previous PR build objects... ***"
      rm -rf ${BELOC}/objs
      echo "mv /pr-objs/objs-${GH_REPO}-${TGBRANCH} ${BELOC}/objs"
      mv /pr-objs/objs-${GH_REPO}-${TGBRANCH} ${BELOC}/objs
      if [ -d "${BELOC}/objs/os" ] ; then
	rm -rf ${BELOC}/os 2>/dev/null
        echo "*** Using previous PR build OS source... ***"
	mv ${BELOC}/objs/os ${BELOC}/os
      fi
    fi
  fi
fi


# Start the XML reporting
clean_xml_results "Clean previous results"
start_xml_results "FreeNAS Build Process"
set_test_group_text "Build phase tests" "2"

OUTFILE="/tmp/fnas-build.out.$$"

echo_test_title "${BUILDSENV} make checkout ${PROFILEARGS}" 2>/dev/null >/dev/null
echo "*** Running: ${BUILDSENV} make checkout ${PROFILEARGS} ***"
${BUILDSENV} make checkout ${PROFILEARGS} 2>&1 #| tee -a ${OUTFILE}
if [ $? -ne 0 ] ; then
  # Try re-checking out SRC bits
  clean_src_repos
  echo "*** Running: ${BUILDSENV} make checkout ${PROFILEARGS} - Clean Checkout ***"
  ${BUILDSENV} make checkout ${PROFILEARGS} 2>&1 #| tee -a ${OUTFILE}
  if [ $? -ne 0 ] ; then
    echo_fail "*** Failed running make checkout ***"
    cat ${OUTFILE}
    finish_xml_results "make"
    exit 1
  fi
fi
echo_ok

# If this build is on the nightlies train, make the changelog
echo ${PROFILEARGS} | grep -q "Nightlies"
if [ $? -eq 0 ] ; then
  echo "Building nightlies ChangeLog"
  make changelog-nightly

  # Set CHANGELOG
  CHANGELOG="${FNASBDIR}/ChangeLog"
  export CHANGELOG
fi

# Ugly hack to get freenas 9.x to build on CURRENT
if [ "$FREENASLEGACY" = "YES" ] ; then

   # Add all the fixes to use a 9.10 version of mtree
   sed -i '' "s|mtree -deU|${PROGDIR}/scripts/kludges/mtree -deU|g" ${FNASSRC}/FreeBSD/src/Makefile.inc1
   sed -i '' "s|mtree -deU|${PROGDIR}/scripts/kludges/mtree -deU|g" ${FNASSRC}/FreeBSD/src/release/Makefile.sysinstall
   sed -i '' "s|mtree -deU|${PROGDIR}/scripts/kludges/mtree -deU|g" ${FNASSRC}/FreeBSD/src/release/picobsd/build/picobsd
   sed -i '' "s|mtree -deU|${PROGDIR}/scripts/kludges/mtree -deU|g" ${FNASSRC}/FreeBSD/src/tools/tools/tinybsd/tinybsd
   sed -i '' "s|mtree -deU|${PROGDIR}/scripts/kludges/mtree -deU|g" ${FNASSRC}/FreeBSD/src/share/examples/Makefile
   sed -i '' "s|mtree -deU|${PROGDIR}/scripts/kludges/mtree -deU|g" ${FNASSRC}/FreeBSD/src/include/Makefile
   sed -i '' "s|mtree -deU|${PROGDIR}/scripts/kludges/mtree -deU|g" ${FNASSRC}/FreeBSD/src/usr.sbin/sysinstall/install.c
   MTREE_CMD="${PROGDIR}/scripts/kludges/mtree"
   export MTREE_CMD

   if [ ! -e "/usr/bin/makeinfo" ] ; then
      cp ${PROGDIR}/scripts/kludges/makeinfo /usr/bin/makeinfo
      chmod 755 /usr/bin/makeinfo
   fi
   if [ ! -e "/usr/bin/mklocale" ] ; then
      cp ${PROGDIR}/scripts/kludges/mklocale /usr/bin/mklocale
      chmod 755 /usr/bin/mklocale
   fi
   if [ ! -e "/usr/bin/install-info" ] ; then
      cp ${PROGDIR}/scripts/kludges/install-info /usr/bin/install-info
      chmod 755 /usr/bin/install-info
   fi

   # Copy our kludged build_jail.sh
   cp ${PROGDIR}/scripts/kludges/build_jail.sh ${FNASSRC}/build/build_jail.sh

   # NANO_WORLDDIR expects this to exist
   if [ ! -d "/var/home" ] ; then
      mkdir /var/home
   fi

   # Fix a missing directory in NANO_WORLDDIR
   sed -i '' 's|geom_gate.ko|geom_gate.ko;mkdir -p ${NANO_WORLDDIR}/usr/src/sys|g' ${FNASSRC}/build/nanobsd-cfg/os-base-functions.sh

   # Check if grub2-efi is on the builder, remove it so
   pkg info -q grub2-efi
   if [ $? -eq 0 ] ; then
     pkg delete -y grub2-efi
   fi
fi

# Set to use TMPFS for everything
if [ -e "build/config/templates/poudriere.conf" ] ; then
  echo "*** Enabling USE_TMPFS=$TMPFSWORK ***"
  sed -i '' "s|USE_TMPFS=yes|USE_TMPFS=$TMPFSWORK|g" build/config/templates/poudriere.conf
  # Set the jail name to use for these builds
  export POUDRIERE_JAILNAME="`echo ${BUILDTAG} | sed 's|\.||g'`"

fi


# We are doing a build as a result of a PR
# Lets copy the repo from WORKSPACE into the correct location
if [ -n "${PRBUILDER}" -a "$PRBUILDER" != "build" ] ; then
  cd ${FNASBDIR}
  eval $PROFILEARGS

  echo "*** Replacing repo with PR-updated version ***"
  rm -rf "${PROFILE}/_BE/${PRBUILDER}"
  mkdir "${PROFILE}/_BE/${PRBUILDER}"
  echo "${WORKSPACE} -> ${PROFILE}/_BE/${PRBUILDER}"
  tar cf - -C "${WORKSPACE}" . | tar xf - -C "${PROFILE}/_BE/${PRBUILDER}"
  if [ $? -ne 0 ] ; then exit_clean; fi
fi

# Check for other PR repos to pull in
check_pr_depends

# FreeBSD head removed lint, disable it
export LINT=""

# Clear the OUTFILE
echo "" > ${OUTFILE}

echo_test_title "${BUILDSENV} make release ${PROFILEARGS}" 2>/dev/null >/dev/null
echo "*** ${BUILDSENV} make release ${PROFILEARGS} ***"
${BUILDSENV} make release ${PROFILEARGS} 2>&1 #| tee -a ${OUTFILE}
if [ $? -ne 0 ] ; then
  echo_fail "Failed running make release"
  #parse_build_error "${OUTFILE}"
  clean_artifacts
  save_artifacts_on_fail
  finish_xml_results "make"
  exit 1
fi
export ARTIFACTONSUCCESS=TRUE
echo_ok
clean_artifacts
save_artifacts_on_success
finish_xml_results "make"

cd ${FNASBDIR}
eval $PROFILEARGS
if [ ! -d "${PROFILE}/_BE/release" ] ; then
  echo "ERROR: Could not locate release dir: ${PROFILE}/_BE/release"
fi
echo "*** Saving build artifacts ***"
if [ ! -d "${WORKSPACE}/artifacts" ] ; then
  mkdir -p "${WORKSPACE}/artifacts/"
fi
cp -r ${PROFILE}/_BE/release/* "${WORKSPACE}/artifacts/"


# Locate the ISO file
ISOFILE=`find "${WORKSPACE}/artifacts" | grep \.iso$ | head -n 1`
ISODIR="`dirname $ISOFILE`"
if [ -d "$ISODIR" ] ; then
  echo "*** Moving ISO files ($ISODIR) to artifacts/iso ***"
  rm -rf "${WORKSPACE}/artifacts/iso"
  mv "${ISODIR}" "${WORKSPACE}/artifacts/iso"
fi

# Copy the sources into the artifact repo as well
echo "*** Copying sources to artifacts/ ***"
rm -rf "${WORKSPACE}/artifacts/src"
mkdir -p "${WORKSPACE}/artifacts/src"

eval $PROFILEARGS

# Disable for now, we may be able to use the already-checked out dirs via pipelines for QA testing now
# KPM - 2-3-2018
#for srcdir in freenas webui
#do
#  echo "*** Copying $srcdir to artifacts/src/$srcdir ***"
#  mkdir -p "${WORKSPACE}/artifacts/src/${srcdir}"
#  tar cf - -C "${FNASBDIR}/${PROFILE}/_BE/${srcdir}" . | tar xf - -C "${WORKSPACE}/artifacts/src/$srcdir"
#  if [ $? -ne 0 ] ; then exit_clean; fi
#done

echo "*** Flushing artifacts to disk ***"
chown -R jenkins:jenkins "${WORKSPACE}"
if [ -d "${WORKSPACE}/artifacts/logs" ] ; then
  chmod -R 755 "${WORKSPACE}/artifacts/logs"
fi
sync

# Kris Moore (2-2-2018)
#
# The PR builder needs to try and be incremental whenever possible
# This is to keep build times at a minimum so those waiting on merges
# can get their fixes in without horrible wait times (2-5 hours in some cases)
#
# To do this we are going to save a copy of the build objs dir at
# the end of every successful build.
#
# This will be restored before the next build allowing the job to
# only rebuild the world / kernel / pkg bits that have specifically
# changed from the previous run of that particular PR type
if [ -n "${PRBUILDER}" -a -n "$GH_REPO" ] ; then
  cd ${FNASBDIR}

  # First locate the _BE dir
  if [ -d "freenas/_BE/objs" ] ; then
    _BEDIR="freenas/_BE"
  elif [ -d "fn_head/_BE/objs" ] ; then
    _BEDIR="fn_head/_BE"
  elif [ -d "_BE/objs" ] ; then
    _BEDIR="_BE"
  else
    rm ${OUTFILE}
    exit 0
  fi

  # Tar up the objs dir
  if [ ! -d "/pr-objs" ] ; then
    mkdir /pr-objs
  fi

  TGBRANCH=$(echo ${ghprbTargetBranch} | sed 's|/|-|g')
  if [ -d "/pr-objs/objs-${GH_REPO}-${TGBRANCH}" ] ; then
    echo "*** Removing previous PR objects... ***"
    rm -rf /pr-objs/objs-${GH_REPO}-${TGBRANCH} 2>/dev/null
    chflags -R noschg /pr-objs/objs-${GH_REPO}-${TGBRANCH} 2>/dev/null
    rm -rf /pr-objs/objs-${GH_REPO}-${TGBRANCH} 2>/dev/null
  fi
  if [ -d "/pr-objs/objs-${GH_REPO}-${TGBRANCH}" ] ; then
    echo "Warning: Failed to remove previous PR objects:"
    echo "/pr-objs/objs-${GH_REPO}-${TGBRANCH}"
    rm ${OUTFILE}
    exit 0
  fi

  echo "*** Saving PR objects for next run... ***"
  mv ${_BEDIR}/objs /pr-objs/objs-${GH_REPO}-${TGBRANCH}
  if [ $? -ne 0 ] ; then
    echo "Warning: Errors returned saving PR objects"
  fi
  echo "*** Saving PR world for next run... ***"
  mv ${_BEDIR}/os /pr-objs/objs-${GH_REPO}-${TGBRANCH}/

  # Save the location we need to restore to
  echo "${_BEDIR}/objs" > /pr-objs/objs-${GH_REPO}-${TGBRANCH}/belocation

fi

rm ${OUTFILE}
exit 0
