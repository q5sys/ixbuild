#!/bin/sh

# Set the build tag
BUILDTAG="$BUILD"
export BUILDTAG

# Set the repo we pull for build / tests
GITREPO="https://github.com/iXsystems/ixbuild.git"
# Set the branch to use for above repo
if [ -z "$IXBUILDBRANCH" ] ; then
  IXBUILDBRANCH="master"
fi

if [ -f "${PROGDIR}/config/${BUILDTAG}.conf" ] ; then
  . ${PROGDIR}/config/${BUILDTAG}.conf
fi

# Check to see if we should run jails on host
if [ -d "/mnt/tank/ixbuild/" ] ; then
  export JAILED_TESTS=yes

  # Validate jail configuration
  if [ ! -f "${PROGDIR}/config/${BUILDTAG}.conf" ] ; then
    echo "Missing executor configuration in ${PROGDIR}/config/${BUILDTAG}.conf"
    exit 1
  else
    # Until py-iocage supports ip4start/ip4end properties again, or dhcp we must require an interface,IP address, and netmask
    if [ -z "$ip4_addr" ] ; then
      echo "You must specify interfaces ip addresses, and netmasks for jails in ${PROGDIR}/config/${BUILDTAG}.conf"
      echo '"example: ip4_addr="igb0|192.168.58.7/24,igb1|10.20.20.7/23"'
      exit 1
    fi
  fi
fi

# Setup jails for jailed tests
if [ -f "/tmp/${BUILDTAG}" ] ; then
  echo "Entered ${BUILDTAG}"
elif [ -n "$JAILED_TESTS" ] ; then   
  iocage stop $BUILDTAG 2>/dev/null
  iocage destroy -f $BUILDTAG 2>/dev/null
  iocage create -b tag=$BUILDTAG host_hostname=$BUILDTAG allow_raw_sockets=1 ip4_addr="${ip4_addr}" -t executor
  mkdir "/mnt/tank/iocage/tags/$BUILDTAG/root/autoinstalls" 2>/dev/null & 
  mkdir -p "/mnt/tank/iocage/tags/$BUILDTAG/root/mnt/tank/home/jenkins" 2>/dev/null &
  mkdir "/mnt/tank/iocage/tags/$BUILDTAG/root/ixbuild" 2>/dev/null &
  echo "/mnt/tank/autoinstalls /mnt/tank/iocage/tags/$BUILDTAG/root/autoinstalls nullfs rw 0 0" >> "/mnt/tank/iocage/tags/$BUILDTAG/fstab" && \
  echo "/mnt/tank/home/jenkins /mnt/tank/iocage/tags/$BUILDTAG/root/mnt/tank/home/jenkins nullfs rw 0 0" >> "/mnt/tank/iocage/tags/$BUILDTAG/fstab" && \
  echo "/mnt/tank/ixbuild /mnt/tank/iocage/tags/$BUILDTAG/root/ixbuild nullfs rw 0 0" >> "/mnt/tank/iocage/tags/$BUILDTAG/fstab" && \
  echo $WORKSPACE > /mnt/tank/iocage/tags/$BUILDTAG/root/tmp/$BUILDTAG
  iocage set login_flags="-f jenkins" $BUILDTAG
  iocage start $BUILDTAG
fi


# Export WORKSPACE path to jails
if [ -z "$WORKSPACE" ] ; then
  if [ -f "/tmp/$BUILDTAG" ] ; then
    export WORKSPACE=`cat /tmp/$BUILDTAG`
  else
    echo "No WORKSPACE found are we really running through jenkins?"
  fi
fi

cleanup_workdir()
{
  if [ -z "$MASTERWRKDIR" ] ; then return 0; fi
  if [ ! -d "$MASTERWRKDIR" ] ; then return 0 ; fi
  if [ "$MASTERWRKDIR" = "/" ] ; then return 0 ; fi

  # If running on host, lets cleanup
  if [ -z "$JAILED_TESTS" ] ; then
    # Cleanup any leftover mounts
    for i in `mount | grep -q "on ${MASTERWRKDIR}/" | awk '{print $1}' | tail -r`
    do
      umount -f $i
    done
  fi

  # Should be done with unmounts
  mount | grep -q "on ${MASTERWRKDIR}/"
  if [ $? -ne 0 ] ; then
    rm -rf ${MASTERWRKDIR} 2>/dev/null
    chflags -R noschg ${MASTERWRKDIR} 2>/dev/null
    rm -rf ${MASTERWRKDIR}
  fi
  cd
}

exit_clean()
{
  cleanup_workdir
  exit 1
}

create_workdir()
{
  if [ ! -d "/tmp/build" ] ; then
     mkdir /tmp/build
  fi
  cd /tmp/build

  MASTERWRKDIR=`mktemp -d /tmp/build/XXXX` 

  # Vanilla Checkout
  cocmd="git clone --depth=1 -b ${IXBUILDBRANCH} ${GITREPO} ${MASTERWRKDIR}"
  echo "Cloning with: $cocmd"
  $cocmd
  if [ $? -ne 0 ] ; then exit_clean; fi

  cd ${MASTERWRKDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  # Copy over user builds
  if [ -d "/ixbuild/builds" ] ; then
    rm -rf ${MASTERWRKDIR}/builds
    cp -r /ixbuild/builds ${MASTERWRKDIR}/builds
  fi

  echo "$BUILDTAG" | grep -q -e "freenas" -e "truenas"
  if [ $? -eq 0 ] ; then
    TBUILDDIR="${MASTERWRKDIR}/freenas"
  else
    echo "$BUILDTAG" | grep -q -e "trueos" -e "pico"
    if [ $? -eq 0 ] ; then
      TBUILDDIR="${MASTERWRKDIR}/trueos"
    else
      TBUILDDIR="${MASTERWRKDIR}/pcbsd"
    fi
  fi

  cp ${BDIR}/${BUILD}/* ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi
}

push_pkgworkdir()
{
  cd ${PPKGDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi
  if [ -z "$SFTPHOST" ] ; then return 0; fi

  ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${WORKPKG}" >/dev/null 2>/dev/null

  echo "Pushing cached pkgs..."
  rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${WORKPKG}/ >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
  if [ $? -ne 0 ] ; then tail -50 ${MASTERWRKDIR}/push.log ; exit_clean; fi
}


pull_pkgworkdir()
{
  if [ -z "$SFTPHOST" ] ; then return 0; fi

  # Check if we have any workdirs to re-sync
  ssh ${SFTPUSER}@${SFTPHOST} "ls ${WORKPKG}" >/dev/null 2>/dev/null
  if [ $? -ne 0 ] ; then
     return 0
  fi

  if [ ! -d "${PPKGDIR}" ] ; then
    mkdir -p ${PPKGDIR}
  fi

  cd ${PPKGDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  echo "Pulling cached pkgs..."
  rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${WORKPKG}/ . >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log

  if [ $? -ne 0 ] ; then tail -50 ${MASTERWRKDIR}/push.log ; exit_clean; fi
}

push_world()
{
  cd ${TBUILDDIR}/fbsd-dist
  if [ $? -ne 0 ] ; then exit_clean; fi

  # Pushing to a local directory?
  if [ -z "$SFTPHOST" ] ; then
    if [ ! -d "${PCBSDBDIR}/fbsd-dist/${WORLDTREL}" ] ; then mkdir -p ${PCBSDBDIR}/fbsd-dist/${WORLDTREL}; fi
    rm ${PCBSDBDIR}/fbsd-dist/${WORLDTREL}/* 2>/dev/null
    echo "Saving FreeBSD dist files -> ${PCBSDBDIR}/fbsd-dist/${WORLDTREL}"
    cp * ${PCBSDBDIR}/fbsd-dist/${WORLDTREL}/
    return 0
  fi

  # Push world packages to work directory
  ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${WORKWORLD}" >/dev/null 2>/dev/null

  rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${WORKWORLD}/ >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
  if [ $? -ne 0 ] ; then tail -50 ${MASTERWRKDIR}/push.log ; exit_clean; fi

  if [ -n "$PKGBASE" ] ; then
    # Push packages to base directory
    cd ${TBUILDDIR}/fbsd-pkg
    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${PKGSTAGE}-base" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${PKGSTAGE}-base/ >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
  fi

  # Dist files to dist directory
  cd ${TBUILDDIR}/fbsd-dist
  ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${ISOSTAGE}/dist" >/dev/null 2>/dev/null
  rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${ISOSTAGE}/dist/ >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
}

pull_world()
{
  if [ ! -d "${TBUILDDIR}/fbsd-dist" ] ; then
    mkdir -p ${TBUILDDIR}/fbsd-dist
  fi

  # Pulling from a local dist set
  if [ -z "$SFTPHOST" ] ; then
    if [ ! -d "${PCBSDBDIR}/fbsd-dist/${WORLDTREL}" ] ; then return 1; fi
    cp ${PCBSDBDIR}/fbsd-dist/${WORLDTREL}/* ${TBUILDDIR}/fbsd-dist/
    if [ $? -ne 0 ] ; then
      return 1
    fi
    return 0
  fi

  # Pulling from a remote dist set

  # Check if the world exists
  ssh ${SFTPUSER}@${SFTPHOST} "ls ${WORKWORLD}" >/dev/null 2>/dev/null
  if [ $? -ne 0 ] ; then
     return 1
  fi

  if [ -n "$PKGBASE" ] ; then
    # Push packages to base directory
    mkdir ${TBUILDDIR}/fbsd-pkg
    cd ${TBUILDDIR}/fbsd-pkg
    if [ $? -ne 0 ] ; then exit_clean; fi
    echo "Pulling base packages..."
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${PKGSTAGE}-base/ . >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
  fi

  cd ${TBUILDDIR}/fbsd-dist
  if [ $? -ne 0 ] ; then exit_clean; fi

  rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${WORKWORLD}/ . >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
  if [ $? -ne 0 ] ; then tail -50 ${MASTERWRKDIR}/push.log ; exit_clean; fi
  return 0
}

pull_iso()
{
  if [ -z "$SFTPHOST" ] ; then return 0; fi

  # Check if we have any workdirs to re-sync
  ssh ${SFTPUSER}@${SFTPHOST} "ls ${ISOSTAGE}" >/dev/null 2>/dev/null
  if [ $? -ne 0 ] ; then
     return 0
  fi

  if [ ! -d "${TBUILDDIR}/iso" ] ; then
    mkdir -p ${TBUILDDIR}/iso
  fi

  cd ${TBUILDDIR}/iso
  if [ $? -ne 0 ] ; then exit_clean; fi

  rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${ISOSTAGE}/ . >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
  if [ $? -ne 0 ] ; then tail -50 ${MASTERWRKDIR}/push.log ; exit_clean; fi
}

jenkins_world()
{
  create_workdir

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  make world
  if [ $? -ne 0 ] ; then exit_clean; fi

  push_world

  if [ -z "$1" ] ; then
    cleanup_workdir
  fi
}

jenkins_jail()
{
  create_workdir

  pull_world
  if [ $? -ne 0 ] ; then
    jenkins_world "1"
    pull_world
    if [ $? -ne 0 ] ; then
       exit_clean "Failed getting world files"
    fi
  fi

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  make jail
  if [ $? -ne 0 ] ; then exit_clean; fi

  cleanup_workdir

  exit 0
}

jenkins_pkg()
{
  create_workdir

  # Pull in the world directory
  pull_world
  if [ $? -ne 0 ] ; then
    jenkins_world "1"
    pull_world
    if [ $? -ne 0 ] ; then
       exit_clean "Failed getting world files"
    fi
  fi

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  # Check if we have a more current pkg set on the local box
  if [ -n "$SFTPHOST" ] ; then
    remotetime=`ssh ${SFTPUSER}@${SFTPHOST} "cat ${PKGSTAGE}/.started" 2>/dev/null`
    localtime=`cat ${PPKGDIR}/.started 2>/dev/null`
    if [ -n "$remotetime" -a -n "$localtime" ] ; then
      if [ $remotetime -lt $localtime ] ; then
        push_pkgworkdir
      fi
    fi
  fi

  cd ${TBUILDDIR}
  make ports-update-all
  if [ $? -ne 0 ] ; then exit_clean; fi

  # Pull the workdir from the cache
  pull_pkgworkdir

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  # Save the timestamp of when we started this poud run
  if [ ! -d "${PPKGDIR}" ] ; then mkdir -p ${PPKGDIR} ; fi
  date +"%s" >${PPKGDIR}/.started

  # Make the release or ISO packages
  if [ "$1" = "release" ] ; then
    make ports
    if [ $? -ne 0 ] ; then push_pkgworkdir; exit_clean; fi
  else
    make iso-ports
    if [ $? -ne 0 ] ; then push_pkgworkdir; exit_clean; fi
  fi

  # Push over the workdir to the cache
  push_pkgworkdir

  # Yay, success! Lets rsync the package set to staging machine
  cd $PPKGDIR
  if [ $? -ne 0 ] ; then exit_clean; fi

  if [ -n "$SFTPHOST" ] ; then
    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${PKGSTAGE}" >/dev/null 2>/dev/null

    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${PKGSTAGE} >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
    if [ $? -ne 0 ] ; then tail -50 ${MASTERWRKDIR}/push.log ; exit_clean; fi
  fi

  cleanup_workdir

  exit 0
}

jenkins_iso()
{
  create_workdir

  pull_world

  # Pull the workdir from the cache
  pull_pkgworkdir

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  make image
  if [ $? -ne 0 ] ; then exit_clean; fi

  # Now lets sync the ISOs
  cd ${TBUILDDIR}/iso
  if [ $? -ne 0 ] ; then exit_clean; fi

  if [ -n "$SFTPHOST" ] ; then
    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${ISOSTAGE}" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${ISOSTAGE} >${MASTERWRKDIR}/push.log 2>${MASTERWRKDIR}/push.log
    if [ $? -ne 0 ] ; then tail -50 ${MASTERWRKDIR}/push.log ; exit_clean; fi
  fi

  # Do ISO artifact creation for Jenkins
  if [ -d "${WORKSPACE}" ] ; then
     rm -rf "${WORKSPACE}/iso"
     mkdir -p "${WORKSPACE}/iso"
     cp -r ${TBUILDDIR}/iso/* "${WORKSPACE}/iso"
     chown -R jenkins:jenkins "${WORKSPACE}"
  fi

  cleanup_workdir

  exit 0
}
generatePackageManifestFile()
{
  #inputs: 1: Directory of package files (*.txz), 2: text file for manifest
  #Note: This will **append** the manifest info to the file!!
  _pkgdir=$1
  _pkgfile=$2
  for _line in `find "${_pkgdir}" -depth 1 -name "*.txz" | sort`
  do
    #Cleanup the individual line (directory, suffix)
    _line=$(echo ${_line} | rev | cut -d "/" -f 1| rev | sed "s|.txz||g")
    #Make sure it is a valid package name - otherwise skip it
    case "${_line}" in
	fbsd-distrib) continue ;;
	*-*) ;;
	*) continue ;;
    esac
    #Grab the version tag (ignore the first word - name might start with a number)
    _version=$(echo ${_line} | cut -d '-' -f 2-12 | rev | cut -d '-' -f 1-2 | rev)
    #check that the version string starts with a number, otherwise only use the last "-" section
    _tmp=$(echo ${_version} | egrep '^[0-9]+')
    if [ -z "${_tmp}" ] ; then
      _version=$(echo ${_line} | rev | cut -d '-' -f 1 | rev)
    fi
    _name=$(echo ${_line} | sed "s|-${_version}||g")
    echo "${_name} : ${_version}" >> ${_pkgfile}
    #echo "Name: ${_name}  : Version: ${_version}"
    #echo "  -raw line: ${line}"
  done
  #cleanup the temporary variables
  unset _pkgdir
  unset _pkgfile
  unset _line
  unset _name
  unset _version
  unset _tmp
}

jenkins_publish_pkg()
{
  if [ ! -d "${SFTPFINALDIR}/pkg/${TARGETREL}" ] ; then
    echo "Missing packages to push!"
    exit 1
  fi

  if [ ! -e "${SFTPFINALDIR}/pkg/${TARGETREL}/pkg_manifest.pkglist" ] ; then
    #Note: There are two pkg publish jobs - so only generate the manifest if it has not already been created
    echo "Generating package manifest..."
    _all_pkgs_dir="amd64/All"  #Relative to the release dir
    _base_pkgs_dir="amd64-base"
    generatePackageManifestFile "${SFTPFINALDIR}/pkg/${TARGETREL}/${_all_pkgs_dir}" "${SFTPFINALDIR}/pkg/${TARGETREL}/pkg_manifest.pkglist"
    generatePackageManifestFile "${SFTPFINALDIR}/pkg/${TARGETREL}/${_base_pkgs_dir}" "${SFTPFINALDIR}/pkg/${TARGETREL}/FreeBSD_manifest.pkglist"
    unset _all_pkgs_dir
    unset _base_pkgs_dir
  fi

  # Set target locations
  scale="pcbsd@pcbsd-master.scaleengine.net"
  target="/usr/home/pcbsd/mirror/pkg"

  case ${1} in
	  edge) RTARGET="${TARGETREL}/edge" ;;
	  unstable) RTARGET="${TARGETREL}/unstable" ;;
	  *) RTARGET="${TARGETREL}" ;;
  esac

  # Make sure remote target exists
  echo "ssh ${scale} mkdir -p ${target}/${RTARGET}"
  ssh ${scale} "mkdir -p ${target}/${RTARGET}" >/dev/null 2>/dev/null

  # Copy packages
  rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" ${SFTPFINALDIR}/pkg/${TARGETREL}/ ${scale}:${target}/${RTARGET}/
  if [ $? -ne 0 ] ; then exit_clean; fi

}

jenkins_publish_pkg_ipfs()
{
  # Location of our ipfs-cluster-ctl command
  PATH="${PATH}:/root/bin"
  export PATH

  # Now lets sync the docs
  if [ -z "$SFTPHOST" ] ; then exit 1; fi

  tstamp=$(date +%s)

  echo "mkdir -p /root/trueos/${TARGETREL}/${tstamp}"
  mkdir -p /root/trueos/${TARGETREL}/${tstamp}
  rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${SFTPFINALDIR}/pkg/${TARGETREL}/ /root/trueos/${TARGETREL}/${tstamp}
  if [ $? -ne 0 ] ; then exit_clean ; fi

  if [ ! -e "/root/trueos/${TARGETREL}/${tstamp}/manifest.pkglist" ] ; then
    #Note: There are two pkg publish jobs - so only generate the manifest if it has not already been created
    echo "Generating package manifest..."
    generatePackageManifestFile "/root/trueos/${TARGETREL}/${tstamp}" "/root/trueos/${TARGETREL}/${tstamp}/manifest.pkglist"
  fi

  # Which hash file we are updating
  if [ -n "$1" -a "$1" = "stable" ] ; then
    HFILE="trueos-ipfs-stable"
    KEEPHASH="2"
  else
    HFILE="trueos-ipfs-unstable"
    KEEPHASH="3"
  fi

  echo "Setting permissions on /root/trueos/${TARGETREL}/${tstamp}"
  chown -R root:wheel /root/trueos/${TARGETREL}/${tstamp}

  # Copy packages
  echo "Adding packages to IPFS, this will take a while..."
  ipfs-go config --json Experimental.FilestoreEnabled true
  echo "ipfs-go add --nocopy -r -Q --pin /root/trueos/${TARGETREL}/${tstamp}"
  PKGHASH=$(ipfs-go add --nocopy -r -Q --pin /root/trueos/${TARGETREL}/${tstamp})
  if [ $? -ne 0 ] ; then exit_clean; fi

  echo "Finished Adding: $PKGHASH"

  echo "Pinning to IPFS cluster: $PKGHASH"
  ipfs-cluster-ctl pin add ${PKGHASH}

  # Save hash to list of pins
  echo "$tstamp $PKGHASH" >>/var/db/${HFILE}

  # Unpin hashes beyond the KEEPHASH
  PRUNEHASH=$(expr $KEEPHASH + 1)
  cat /var/db/${HFILE} | sort -r | tail -n +${PRUNEHASH} | while read line
  do
    otstamp=$(echo $line | awk '{print $1}')
    ohash=$(echo $line | awk '{print $2}')
    echo "Unpinning: $ohash"
    ipfs-cluster-ctl pin rm $ohash
    if [ -d "/root/trueos/${TARGETREL}/${otstamp}" ] ; then
      echo "Removing pruned package files: /root/trueos/${TARGETRE}/${otstamp}"
      rm -rf "/root/trueos/${TARGETREL}/${otstamp}"
    fi
  done

  # Pruning of old pinned hashes
  cat /var/db/${HFILE} | sort -r | head -n ${KEEPHASH} >/var/db/${HFILE}.new
  mv /var/db/${HFILE}.new /var/db/${HFILE}

  # Publish HASH to trueos-ipfs-unstable file
  scp /var/db/${HFILE} kris@web.pcbsd.org:updates/${HFILE}
  if [ $? -ne 0 ] ; then exit_clean; fi

}

jenkins_promote_pkg()
{
  # Set target locations
  scale="pcbsd@pcbsd-master.scaleengine.net"
  mdate=$(date "+%y%m%d%H")
  if [ -n "TARGETDATE" ] ; then
    mdate="$TARGETDATE"
  fi
  otarget="/usr/home/pcbsd/mirror/pkg/master/edge"
  ntarget="/usr/home/pcbsd/mirror/pkg/master-${mdate}"

  # Make new master-<DATE> directory
  ssh ${scale} "mkdir -p ${target}"

  # Copy over the amd64-base packages from UNSTABLE -> STABLE
  rcmd="rsync -va --delete-delay --delay-updates ${otarget}/amd64-base/ ${ntarget}/amd64-base/"
  echo "Running on remote: $rcmd"
  ssh ${scale} "$rcmd"
  if [ $? -ne 0 ] ; then exit_clean; fi

  # Copy over the amd64 packages from UNSTABLE -> STABLE
  rcmd="rsync -va --delete-delay --delay-updates ${otarget}/amd64/ ${ntarget}/amd64/"
  echo "Running on remote: $rcmd"
  ssh ${scale} "$rcmd"
  if [ $? -ne 0 ] ; then exit_clean; fi

  echo "Packages promoted to: ${target}"
  echo "Don't forget to sym-link master -> ${target}"
}

generateJsonObjectForImage()
{
i=$1

# Now add the information about this file to the JSON manifest
    if [ -n "${_PUSH_JSON_FILE}" ] ; then
      _PUSH_JSON_FILE="${_PUSH_JSON_FILE}, " #add the comma separation between elements
    fi
    _name=`echo ${i} | cut -d - -f 2` #Desktop or Server
    _filetype=`echo ${i} | rev | cut -d . -f 1 | rev` #iso or img
    _imgtype=`echo ${i} | cut -d - -f 6` #UNSTABLE or <junk>
    _type=`echo ${i} | rev | cut -d . -f 2 | cut -d - -f 1 | rev` #DVD or USB
    _date=`date "+%Y-%m-%d"`
    if [ ! "UNSTABLE" == "${_imgtype}" ] ; then
      _imgtype="STABLE"
      _dateversion=`echo ${i} | cut -d - -f 3` #YY.MM
    else
      _dateversion=`echo ${i} | cut -d - -f 3-5` #YYYY-MM-DD
    fi
    _sha256=`cat ${i}.sha256`
    
    _PUSH_JSON_FILE="${_PUSH_JSON_FILE} { \"name\":\"TrueOS ${_name} (${_type} image)\",  \"date\":\"${_date}\", \"version\":\"${_dateversion}\", \"sha256\":\"${_sha256}\", \"type\":\"${_imgtype}\", \"platform\":\"${_name}\", \"filetype\":\"${_filetype}\", \"url\":\"${i}\""
    for j in "md5" "sha256" "sig" "torrent"
    do
      if [ -e "${i}.${j}" ] ; then
        _PUSH_JSON_FILE="${_PUSH_JSON_FILE}, \"${j}_url\":\"${i}.${j}\""
      fi
    done
    _PUSH_JSON_FILE="${_PUSH_JSON_FILE} }" #close off the json object
  #clean up the internal variables
  unset _name
  unset _filetype
  unset _imgtype
  unset _type
  unset _dateversion
  unset _date
  unset _sha256
}

jenkins_publish_iso()
{
  if [ ! -d "${SFTPFINALDIR}/iso/${TARGETREL}" ] ; then
    echo "Missing iso to push!"
    exit 1
  fi

  if [ -n "$1" -a "$1" = "edge" ] ; then
    RTARGET="${TARGETREL}/edge"
  else
    RTARGET="${TARGETREL}"
  fi

  # Set the targets
  scale="pcbsd@pcbsd-master.scaleengine.net"
  target="/usr/home/pcbsd/mirror/iso"
  ssh ${scale} "mkdir -p ${target}/${RTARGET}/${ARCH}" >/dev/null 2>/dev/null

  # We sign the ISO's with gpg
  cd ${SFTPFINALDIR}/iso/${TARGETREL}/${ARCH}/
  if [ $? -ne 0 ] ; then exit_clean; fi
  unset _PUSH_JSON_FILE #Make sure this internal variable is cleared first
  for i in `ls *.iso *.img *.xz`
  do
    echo "Signing: $i"
    rm ${i}.sig >/dev/null 2>/dev/null
    gpg -u releng@trueos.org --output ${i}.sig --detach-sig ${i}
    # Now add the information about this file to the JSON manifest
    _latest=`echo ${i} | cut -d - -f 1`
    if [ ! "${_latest}" == "latest" ] ; then  #Skip the "latest-[desktop/server]" symlinks
      echo "Adding Image to JSON Manifest: ${i}"
      generateJsonObjectForImage ${i}
    fi
  done
  # Generate the files.json file with all information about the files that are available
  echo "[ ${_PUSH_JSON_FILE} ]" > files.json #make sure to encapulate the list of JSON objects within an array
  unset _PUSH_JSON_FILE #clear it out (done with it)
  # Copy the ISOs
  rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" ${SFTPFINALDIR}/iso/${TARGETREL}/${ARCH}/ ${scale}:${target}/${RTARGET}/${ARCH}/
  if [ $? -ne 0 ] ; then exit_clean; fi
}

jenkins_vm()
{
  create_workdir

  pull_world
  pull_iso

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  make vm
  if [ $? -ne 0 ] ; then exit_clean; fi

  # Now lets sync the ISOs
  cd ${TBUILDDIR}/iso
  if [ $? -ne 0 ] ; then exit_clean; fi

  if [ -n "$SFTPHOST" ] ; then
    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${ISOSTAGE}" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${ISOSTAGE}
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  cleanup_workdir

  exit 0
}

jenkins_truenas_push_docs()
{
  # Now lets upload the docs
  if [ -n "$SFTPHOST" ] ; then
    rm -rf /tmp/handbookpush 2>/dev/null
    mkdir -p /tmp/handbookpush

    # Get the docs from the staging server
    rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/tn-handbook/ /tmp/handbookpush
    if [ $? -ne 0 ] ; then exit_clean; fi

    cd /tmp/handbookpush
    if [ $? -ne 0 ] ; then exit_clean ; fi

    # Make them live!
    rsync -a -O -v -z --delete -e 'ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa.jenkins' . jenkins@support.ixsystems.com:/usr/local/www/vhosts/truenas-guide
    if [ $? -ne 0 ] ; then exit_clean; fi
    rm -rf /tmp/handbookpush 2>/dev/null
  fi

  return 0
}

jenkins_freenas_push_be()
{
  # Figure out the flavor for this test
  echo $BUILDTAG | grep -q "truenas"
  if [ $? -eq 0 ] ; then
    FLAVOR="truenas"
  else
    FLAVOR="freenas"
  fi
  if [ -z "${RSYNCHOST}" ] ; then
    exit 1
    echo "Missing $RSYNCHOST"
  fi
  if [ -z "${PUSHPATH}" ] ; then
    exit 1
    echo "Missing $PUSHPATH"
  fi
  ssh $RSYNCHOST mkdir -p $PUSHPATH/$FLAVOR/$JENKINSVERSION 2>/dev/null
  rsync -avh /$BUILDTAG/freenas/_BE/repo-manifest $RSYNCHOST:$PUSHPATH/$FLAVOR/$JENKINSVERSION/build_env/
  rsync -avh /$BUILDTAG/freenas/_BE/objs/debug/ $RSYNCHOST:$PUSHPATH/$FLAVOR/$JENKINSVERSION/build_env/debug/
  rsync -avh /$BUILDTAG/freenas/_BE/objs/world/ $RSYNCHOST:$PUSHPATH/$FLAVOR/$JENKINSVERSION/build_env/world/
  rsync -avh /$BUILDTAG/freenas/_BE/release/ $RSYNCHOST:$PUSHPATH/$FLAVOR/$JENKINSVERSION/release/
}
jenkins_freenas_push_docs()
{
  # Now lets upload the docs
  if [ -n "$SFTPHOST" ] ; then
    rm -rf /tmp/handbookpush 2>/dev/null
    mkdir -p /tmp/handbookpush

    # Get the docs from the staging server
    rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/handbook/ /tmp/handbookpush
    if [ $? -ne 0 ] ; then exit_clean; fi

    cd /tmp/handbookpush
    if [ $? -ne 0 ] ; then exit_clean ; fi

    # Make them live!
    rsync -a -v -z --delete --exclude "truenas*" -e 'ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa.jenkins' . jenkins@api.freenas.org:/tank/doc/userguide/html11
    if [ $? -ne 0 ] ; then exit_clean; fi
    rm -rf /tmp/handbookpush 2>/dev/null
  fi

  return 0
}

jenkins_freenas_push_api()
{
  # Now lets upload the docs
  if [ -n "$SFTPHOST" ] ; then
    rm -rf /tmp/apipush 2>/dev/null
    mkdir -p /tmp/apipush

    # Get the docs from the staging server
    rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/api/ /tmp/apipush
    if [ $? -ne 0 ] ; then exit_clean; fi

    cd /tmp/apipush
    if [ $? -ne 0 ] ; then exit_clean ; fi

    # Make them live!
    rsync -a -v -z --delete --exclude "truenas*" -e 'ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa.jenkins' . jenkins@api.freenas.org:/tank/api/html
    if [ $? -ne 0 ] ; then exit_clean; fi

    rm -rf /tmp/apipush 2>/dev/null
  fi

  return 0
}

jenkins_freenas_push()
{
  # Sanity check that the build was done on this node
  if [ ! -d "${FNASBDIR}" ] ; then
    echo "ERROR: No such build dir: ${FNASBDIR}"
    exit 1
  fi

  cd ${FNASBDIR}
  if [ $? -ne 0 ] ; then exit_clean ; fi

  git reset --hard
  git pull

  PROFILEARGS="$BUILDOPTS"

  if [ -z "$JENKINSVERSION" ] ; then
    echo "ERROR: Missing JENKINSVERSION="
  fi
  PROFILEARGS="${PROFILEARGS} VERSION=$JENKINSVERSION"

  if [ -n "$JENKINSINTUPDATE" -a "$JENKINSINTUPDATE" = "true" ] ; then
    PROFILEARGS="${PROFILEARGS} INTERNAL_UPDATE=yes"
  else
    if [ -z "$RELENG_PASSWORD" ] ; then
      echo "ERROR: Pushing public with no password set!"
      exit 1
    fi
  fi

  if [ -n "$RELENG_PASSWORD" ] ; then
    # Set the correct variable release-push expects
    echo "Setting IX_KEY_PASSWORD from RELENG_PASSWORD"
    IX_KEY_PASSWORD="${RELENG_PASSWORD}"
    export IX_KEY_PASSWORD
  fi

  # Skip deltas for now
  DELTAS="0"
  export DELTAS

  # Push the release to download.freenas.org
  echo "make release-push ${PROFILEARGS}"
  make release-push ${PROFILEARGS}
  if [ $? -ne 0 ] ; then exit_clean ; fi

  return 0
}

jenkins_freenas_push_nightly()
{
  # Sanity check that the build was done on this node
  if [ ! -d "${FNASBDIR}" ] ; then
    echo "ERROR: No such build dir: ${FNASBDIR}"
    exit 1
  fi

  cd ${FNASBDIR}
  if [ $? -ne 0 ] ; then exit_clean ; fi

  # Set CHANGELOG
  if [ -e "${FNASBDIR}/ChangeLog" ] ; then
    echo "Setting CHANGELOG: ${FNASBDIR}/ChangeLog"
    CHANGELOG="${FNASBDIR}/ChangeLog"
    export CHANGELOG
  fi

  # Skip deltas
  DELTAS="0"
  export DELTAS

  if [ -z "$JENKINSINTUPDATE" -o "$JENKINSINTUPDATE" = "false" ] ; then
    PROFILEARGS="${PROFILEARGS}"
  else
    PROFILEARGS="${PROFILEARGS} INTERNAL_UPDATE=yes"
  fi

  # Push the release
  echo "make release-push ${BUILDOPTS} ${PROFILEARGS}"
  make release-push ${BUILDOPTS} ${PROFILEARGS}
  if [ $? -ne 0 ] ; then exit_clean ; fi

  return 0
}

jenkins_truenas_docs()
{
  if [ ! -d "/tmp/build" ] ; then
     mkdir /tmp/build
  fi

  DDIR=`mktemp -d /tmp/build/XXXX` 

  git clone --depth=1 https://github.com/freenas/freenas-docs ${DDIR}
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  cd ${DDIR}/userguide
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  make TAG=truenas html
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi
  mv ${DDIR}/userguide/processed/_build/html ${DDIR}/html

  make TAG=truenas pdf
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  # Put the PDF in the same dir as html
  mv ${DDIR}/html ${DDIR}/userguide/processed/_build/html
  cp ${DDIR}/userguide/processed/_build/latex/*.pdf ${DDIR}/userguide/processed/_build/html/

  # Now lets sync the docs
  if [ -n "$SFTPHOST" ] ; then
    cd ${DDIR}/userguide/processed/_build/html/
    if [ $? -ne 0 ] ; then exit_clean ; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${DOCSTAGE}/tn-handbook" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/tn-handbook
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  rm -rf ${DDIR}

  return 0
}


jenkins_freenas_docs()
{
  if [ ! -d "/tmp/build" ] ; then
     mkdir /tmp/build
  fi

  DDIR=`mktemp -d /tmp/build/XXXX`

  git clone --depth=1 https://github.com/freenas/freenas-docs ${DDIR}
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  cd ${DDIR}/userguide
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  make TAG=freenas html
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  # Now lets sync the docs
  if [ -n "$SFTPHOST" ] ; then
    cd ${DDIR}/userguide/processed/_build/html/
    if [ $? -ne 0 ] ; then exit_clean ; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${DOCSTAGE}/handbook" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/handbook
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  rm -rf ${DDIR}

  return 0
}

jenkins_freenas_api()
{
  if [ ! -d "/tmp/build" ] ; then
     mkdir /tmp/build
  fi

  DDIR=`mktemp -d /tmp/build/XXXX` 

  git clone --depth=1 https://github.com/freenas/freenas ${DDIR}
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  cd ${DDIR}/docs/api
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  make html
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  # Now lets sync the api docs
  if [ -n "$SFTPHOST" ] ; then
    cd ${DDIR}/docs/api/_build/html/
    if [ $? -ne 0 ] ; then exit_clean ; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${DOCSTAGE}/api" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/api
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  cleanup_workdir

  return 0
}

jenkins_sysadm_api()
{
  if [ ! -d "/tmp/build" ] ; then
     mkdir /tmp/build
  fi

  DDIR=`mktemp -d /tmp/build/XXXX`

  git clone --depth=1 https://github.com/trueos/sysadm-docs ${DDIR}
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  cd ${DDIR}/api_reference
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi
  make html
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  # Now lets sync the API docs
  if [ -n "$SFTPHOST" ] ; then
    cd ${DDIR}/api_reference/_build/html/
    if [ $? -ne 0 ] ; then exit_clean ; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${DOCSTAGE}/sysadm-docs/api" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/sysadm-docs/api
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  cleanup_workdir
  return 0
}


jenkins_sysadm_docs()
{
  if [ ! -d "/tmp/build" ] ; then
     mkdir /tmp/build
  fi

  DDIR=`mktemp -d /tmp/build/XXXX` 

  git clone --depth=1 https://github.com/trueos/sysadm-docs ${DDIR}
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  cd ${DDIR}/client_handbook
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi
  make html
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  # Now lets sync the client docs
  if [ -n "$SFTPHOST" ] ; then
    cd ${DDIR}/client_handbook/_build/html/
    if [ $? -ne 0 ] ; then exit_clean ; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${DOCSTAGE}/sysadm-docs/client" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/sysadm-docs/client
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  cd ${DDIR}/server_handbook
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  make html
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  # Now lets sync the server docs
  if [ -n "$SFTPHOST" ] ; then
    cd ${DDIR}/server_handbook/_build/html/
    if [ $? -ne 0 ] ; then exit_clean ; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${DOCSTAGE}/sysadm-docs/server" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/sysadm-docs/server
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  cleanup_workdir
  return 0
}


jenkins_trueos_docs()
{
  if [ ! -d "/tmp/build" ] ; then
     mkdir /tmp/build
  fi

  DDIR=`mktemp -d /tmp/build/XXXX` 

  git clone --depth=1 https://github.com/trueos/trueos-docs ${DDIR}
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  cd ${DDIR}/trueos-handbook
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  make html
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  # Now lets sync the TrueOS docs
  if [ -n "$SFTPHOST" ] ; then
    cd ${DDIR}/trueos-handbook/_build/html/
    if [ $? -ne 0 ] ; then exit_clean ; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${DOCSTAGE}/trueos-docs" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/trueos-docs
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  cleanup_workdir
  return 0
}

jenkins_trueos_push_docs()
{
  cd /outgoing/doc/master/trueos-docs
  if [ $? -ne 0 ] ; then exit_clean ; fi

  rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" . docpush@web.pcbsd.org:/home/pcbsd/www/trueos.org/handbook/
  return 0
}

jenkins_sysadm_push_api()
{
  cd /outgoing/doc/master/sysadm-docs/api
  if [ $? -ne 0 ] ; then exit_clean ; fi

  rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" . docpush@web.pcbsd.org:/home/pcbsd/www/api.sysadm.us/
  return 0
}

jenkins_sysadm_push_docs()
{
  cd /outgoing/doc/master/sysadm-docs/client
  if [ $? -ne 0 ] ; then exit_clean ; fi

  rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" . docpush@web.pcbsd.org:/home/pcbsd/www/sysadm.us/handbook/client

  cd /outgoing/doc/master/sysadm-docs/server
  if [ $? -ne 0 ] ; then exit_clean ; fi

  rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" . docpush@web.pcbsd.org:/home/pcbsd/www/sysadm.us/handbook/server
  return 0
}



jenkins_trueos_lumina_docs()
{
  if [ ! -d "/tmp/build" ] ; then
     mkdir /tmp/build
  fi

  DDIR=`mktemp -d /tmp/build/XXXX` 

  git clone --depth=1 https://github.com/trueos/lumina-docs ${DDIR}
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  cd ${DDIR}
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  make html
  if [ $? -ne 0 ] ; then rm -rf ${DDIR} ; exit 1 ; fi

  # Now lets sync the Lumina docs
  if [ -n "$SFTPHOST" ] ; then
    cd ${DDIR}/_build/html/
    if [ $? -ne 0 ] ; then exit_clean ; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${DOCSTAGE}/lumina-docs" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${DOCSTAGE}/lumina-docs
    if [ $? -ne 0 ] ; then exit_clean; fi
  fi

  cleanup_workdir
  return 0
}

jenkins_trueos_push_lumina_docs()
{
  cd /outgoing/doc/master/lumina-docs
  if [ $? -ne 0 ] ; then exit_clean ; fi

  rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" . docpush@web.pcbsd.org:/home/pcbsd/www/lumina-desktop.org/handbook/
  return 0
}

# Set the FreeNAS _BE directory location
get_bedir()
{
  # Some overrides for github PRs
  if [ -n "$ghprbPullLongDescription" ] ; then
    GITFNASBRANCH="$ghprbTargetBranch"
    if [ "$GITFNASBRANCH" = "freenas/master" -a "$PRBUILDER" = "os" ] ; then
      # When building PRs for the "os" repo on freenas/master branch, use right PROFILE
      BUILDOPTS="PROFILE=fn_head"
    fi

    # Are there PROFILE knobs listed
    echo "$ghprbPullLongDescription" | grep -q "PROFILE:"
    if [ $? -eq 0 ] ; then
      local _profile=`echo $ghprbPullLongDescription | sed -n -e 's/^.*PROFILE: //p' | cut -d '\' -f 1`
      BUILDOPTS="PROFILE=${_profile}"
    fi
  fi

  if [ -n "$BUILDOPTS" ] ; then
    eval $BUILDOPTS
  fi
  echo "$BUILDOPTS" | grep -q fn_head
  if [ $? -eq 0 ] ; then
    PROFILE="fn_head"
    export PROFILE
  fi

  if [ -z "$LEGACYBEDIR" -a -n "${PROFILE}" ] ; then
    export BEDIR="${FNASBDIR}/${PROFILE}/_BE"
    return 0
  else
    export BEDIR="${FNASBDIR}/_BE"
    return 0
  fi
}

jenkins_freenas()
{
  create_workdir

  # Build out all the pipeline variables
  populate_pr_pipeline

  if [ -z "$DISABLE_SHALLOW_CHECKOUT" ] ; then
    # Make sure we always checkout shallow, save us some bandwidth
    export CHECKOUT_SHALLOW="YES"
  fi

  echo ${BUILDTAG} | grep -q "releng"
  if [ $? -eq 0 ] ; then RELENGBUILD="YES" ; fi

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean; fi

  make iso
  if [ $? -ne 0 ] ; then exit_clean; fi

  get_bedir

  # Now lets sync the ISOs (If not a PR build)
  if [ -n "$SFTPHOST" -a -z "$CHANGE_ID" -a -z "$GH_ORG" ] ; then
    if [ "$FREENASLEGACY" = "YES" ] ; then
      cd ${FNASBDIR}/objs
      if [ $? -ne 0 ] ; then exit_clean ; fi
      rm -rf os-base
    else
      cd ${BEDIR}/release
      if [ $? -ne 0 ] ; then
        if [ -d "freenas/_BE/release" ] ; then
	   cd freenas/_BE/release
        elif [ -d "fn_head/_BE/release" ] ; then
	   cd fn_head/_BE/release
	else
           echo "Cannot locate ISO to copy to staging area, skipping"
           exit 0
        fi
      fi
    fi

    if [ -n "${RELENGBUILD}" ] ; then
      # Release Engineer Build
      # Don't cleanup all the old versions
      RSYNCFLAGS=""
      if [ $? -ne 0 ] ; then exit_clean; fi
    else
      RSYNCFLAGS="--delete"
    fi

    # Sync the ISO / Update files now
    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${ISOSTAGE}" >/dev/null 2>/dev/null
    rsync -va ${RSYNCFLAGS} -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${ISOSTAGE}
    if [ $? -ne 0 ] ; then exit_clean; fi

    # Sync the releng build_env
    if [ -n "${RELENGBUILD}" ] ; then
      echo "$BUILD" | grep -q "truenas"
      if [ $? -eq 0 ] ; then
        envdir="/builds/TrueNAS/build_env"
      else
        envdir="/builds/FreeNAS/build_env"
      fi
      if [ ! -d "$envdir" ] ; then
        echo "WARNING: Unable to sync $envdir"
        cleanup_workdir
        return 0
      fi
      cd ${envdir}
      ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${ENVSTAGE}" >/dev/null 2>/dev/null
      rsync -va ${RSYNCFLAGS} -e "ssh -o StrictHostKeyChecking=no" . ${SFTPUSER}@${SFTPHOST}:${ENVSTAGE}
    fi

  fi

  cleanup_workdir

  return 0
}

jenkins_freenas_live_upgrade()
{
  create_workdir

  if [ -z "$LIVEHOST" ] ; then echo "Missing LIVEHOST!" ; exit_clean ; fi
  if [ -z "$LIVEUSER" ] ; then echo "Missing LIVEUSER!" ; exit_clean ; fi
  if [ -z "$LIVEPASS" ] ; then echo "Missing LIVEPASS!" ; exit_clean ; fi

  cd ${TBUILDDIR}
  make liveupgrade
  if [ $? -ne 0 ] ; then exit_clean ; fi

  cleanup_workdir

  return 0
}

jenkins_freenas_live_tests()
{
  create_workdir

  if [ -z "$LIVEHOST" ] ; then echo "Missing LIVEHOST!" ; exit_clean ; fi
  if [ -z "$LIVEUSER" ] ; then echo "Missing LIVEUSER!" ; exit_clean ; fi
  if [ -z "$LIVEPASS" ] ; then echo "Missing LIVEPASS!" ; exit_clean ; fi

  cd ${TBUILDDIR}
  make livetests
  if [ $? -ne 0 ] ; then exit_clean ; fi

  cleanup_workdir

  return 0
}

jenkins_freenas_tests()
{
  create_workdir

  get_bedir

  cd ${TBUILDDIR}
  if [ $? -ne 0 ] ; then exit_clean ; fi

  if [ -n "$SFTPHOST" -a ! -d "${WORKSPACE}/qatarget" ] ; then

    echo "*** Copying ISO from stage dir ***"

    # Now lets sync the ISOs
    if [ -d "${BEDIR}/release" ] ; then
      rm -rf ${BEDIR}/release
    fi
    mkdir -p ${BEDIR}/release
    cd ${BEDIR}/release
    if [ $? -ne 0 ] ; then exit_clean; fi

    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${ISOSTAGE}" >/dev/null 2>/dev/null
    rsync -va --delete --include="*/" --include="*.iso" --exclude="*" -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${ISOSTAGE} ${BEDIR}/release/
    if [ $? -ne 0 ] ; then exit_clean ; fi
  fi

  if [ -d "${WORKSPACE}/qatarget" ] ; then
    echo "*** Copying ISO from artifact ***"

    if [ -d "${BEDIR}/release" ] ; then
      rm -rf ${BEDIR}/release
    fi

    mkdir -p ${BEDIR}/release/FreeNAS-PR/x64
    cd ${BEDIR}/release
    if [ $? -ne 0 ] ; then exit_clean; fi

    cp ${WORKSPACE}/artifacts/FreeNAS-*/x64/*.iso ${BEDIR}/release/FreeNAS-PR/x64/
  fi

  if [ -n "$JAILED_TESTS" ] ; then
    cd ${TBUILDDIR}
    make tests
  else
    cd ${TBUILDDIR}
    make tests
    if [ $? -ne 0 ] ; then exit_clean ; fi
    cleanup_workdir
  fi

  return 0
}

jenkins_freenas_tests_jailed()
{
  iocage chroot $BUILDTAG /ixbuild/jenkins.sh freenas-tests $BUILDTAG
  echo "Exited ${BUILDTAG}"
  jenkins_freenas_run_tests_jailed
}

jenkins_freenas_run_tests()
{
  create_workdir
  cd ${TBUILDDIR}/scripts/
  if [ $? -ne 0 ] ; then exit_clean ; fi
  echo ""
  sleep 10
  pkill -F /tmp/vmcu.pid >/dev/null 2>/dev/null
  echo ""
  echo "Output from REST API calls:"
  echo "-----------------------------------------"
  echo "Running API v1.0 test group create 1/3"
  touch /tmp/$VM-tests-create.log 2>/dev/null
  tail -f /tmp/$VM-tests-create.log 2>/dev/null &
  tpid=$!
  ./9.10-create-tests.sh ip=$FNASTESTIP 2>&1 | tee >/tmp/$VM-tests-create.log
  kill -9 $tpid
  echo ""
  echo "Running API v1.0 test group update 2/3" 
  touch /tmp/$VM-tests-update.log 2>/dev/null
  tail -f /tmp/$VM-tests-update.log 2>/dev/null &
  tpid=$!
  ./9.10-update-tests.sh ip=$FNASTESTIP 2>&1 | tee >/tmp/$VM-tests-update.log
  kill -9 $tpid
  echo ""
  echo "Running API v1.0 test group delete 3/3"
  touch /tmp/$VM-tests-delete.log 2>/dev/null
  tail -f /tmp/$VM-tests-delete.log 2>/dev/null &
  tpid=$!
  ./9.10-delete-tests.sh ip=$FNASTESTIP 2>&1 | tee >/tmp/$VM-tests-delete.log
  kill -9 $tpid
  echo ""
  sleep 10
  if [ -n "${NOMIDDLEWARED}" ] ; then
    echo "Skipping middlewared tests.."
  else
    echo "Running API v2.0 tests"
    touch /tmp/$VM-tests-v2.0.log 2>/dev/null
    tail -f /tmp/$VM-tests-v2.0.log 2>/dev/null &
    tpid=$!
    ./api-v2.0-tests.sh ip=$FNASTESTIP 2>&1 | tee >/tmp/$VM-tests-v2.0.log
    kill -9 $tpid 
    echo ""
    sleep 10
  fi  

  # This runs cleanup_workdir and is bad for jail host
  # if [ $? -ne 0 ] ; then exit_clean ; fi

  # We do not want to cleanup_workdir from a host running jails which will unmount everything
  # This function should be improved to be more specific
  # cleanup_workdir

  return 0
}

jenkins_freenas_run_tests_jailed()
{
  iocage console $BUILDTAG
}


jenkins_push_fn_statedir()
{
  if [ -z "$SFTPHOST" ] ; then return 0 ; fi

  # Now lets push the new state dir
  if [ ! -d "${FNASBDIR}" ] ; then return 0 ; fi

  # Now rsync this sucker
  echo "Copying build-state to remote... ${FNASBDIR}/ -> ${FNSTATEDIR}/"
  rsync -a --delete -e "ssh -o StrictHostKeyChecking=no" ${FNASBDIR}/ ${SFTPUSER}@${SFTPHOST}:${FNSTATEDIR}/
  if [ $? -ne 0 ] ; then exit_clean ; fi
}

jenkins_pull_fn_statedir()
{
  if [ -z "$SFTPHOST" ] ; then return 0 ; fi

  # Make sure the remote dir exists
  ssh ${SFTPUSER}@${SFTPHOST} ls ${FNSTATEDIR}/ >/dev/null 2>/dev/null
  if [ $? -ne 0 ] ; then return 0 ; fi

  # Now lets cleanup old state dir
  if [ -d "${FNASBDIR}" ] ; then 
    echo "Removing local state dir..."
    rm -rf ${FNASBDIR} 2>/dev/null
    chflags -R noschg ${FNASBDIR} 2>/dev/null
    rm -rf ${FNASBDIR}
  fi
  mkdir -p ${FNASBDIR}

  # Now rsync this sucker
  echo "Copying build-state from remote... ${FNSTATEDIR}/ -> ${FNASBDIR}/"
  rsync -a --delete -e "ssh -o StrictHostKeyChecking=no" ${SFTPUSER}@${SFTPHOST}:${FNSTATEDIR}/ ${FNASBDIR}/
  if [ $? -ne 0 ] ; then exit_clean ; fi

  # Make sure to set proper ownership
  chown -R root:wheel ${FNASBDIR}
}

jenkins_ports_tests()
{
  echo "Changing to $WORKSPACE"
  cd "$WORKSPACE"
  if [ $? -ne 0 ] ; then exit 1 ; fi

  ./mkport.sh /usr/ports
  if [ $? -ne 0 ] ; then exit 1 ; fi

  # Now determine the port to build
  if [ -z "${bPort}" ] ; then
    echo "bPort variable not set: Try to auto-calculate it..."
    bPort=`cat mkport.sh | grep ^port= | cut -d '"' -f 2`
    if [ -z "$bPort" ] ; then
      echo "ERROR: Unable to determine bPort="
      exit 1
    fi
  fi
  echo "Test build port(s): ${bPort}"
  for _port in ${bPort}
  do
    echo "[STARTING BUILD] ${_port}"
    #Quick skip of any empty variables
    if [ -z "${_port}" ] ; then continue; fi

    cd /usr/ports/${_port}
    if [ $? -ne 0 ] ; then exit 1; fi

    make clean
    if [ $? -ne 0 ] ; then exit 1; fi

    portlint
    if [ $? -ne 0 ] ; then exit 1; fi

    make BATCH=yes
    if [ $? -ne 0 ] ; then exit 1 ; fi

    make stage
    if [ $? -ne 0 ] ; then exit 1 ; fi

    make check-plist
    if [ $? -ne 0 ] ; then exit 1 ; fi
  done
  
  exit 0
}

jenkins_mktrueview()
{
  cd /root

  # Roll back to clean snapshot
  VBoxManage snapshot trueview restore clean
  if [ $? -ne 0 ] ; then
    echo "Failed to roll-back to @clean snapshot"
    exit 1
  fi

  # Start the trueview VM and wait for it to finish
  ( VBoxHeadless -s trueview >/dev/null 2>/dev/null ) &
  count=0

  echo "Waiting for TrueView prep to finish..."
  while :
  do
    sleep 60
    echo "."

    vboxmanage list runningvms | grep -q "trueview"
    if [ $? -ne 0 ] ; then
      break
    fi

    count=`expr $count + 1`
    if [ $count -gt 20 ] ; then
      VBoxManage controlvm trueview poweroff
      exit 1
    fi
  done

  rm -rf /root/trueview/
  mkdir /root/trueview
  OUTFILE=/root/trueview/trueview-`date '+%Y-%m-%d-%H-%M'`

  # Looks like trueview finished on its own, lets package it up
  VBoxManage modifyvm trueview --nic1 bridged

  echo "Exporting TrueView .ova file..."
  VBoxManage export trueview -o ${OUTFILE}.ova
  chmod 644 ${OUTFILE}.ova
  echo "Exporting TrueView legacy .ova file..."
  VBoxManage export trueview -o ${OUTFILE}-legacy.ova --legacy09
  chmod 644 ${OUTFILE}-legacy.ova
  echo "Exporting TrueView ovf20 .ova file..."
  VBoxManage export trueview -o ${OUTFILE}-ovf20.ova --ovf20
  chmod 644 ${OUTFILE}-ovf20.ova

  # Export the RAW disk image
  dimg=`ls /root/VirtualBox\ VMs/trueview/trueview*.vmdk`
  vboxmanage clonemedium "$dimg" /root/trueview/trueview.vmdk --format VMDK --variant Fixed,ESX
  cd /root/trueview
  zip -r ${OUTFILE}-vmdk.zip trueview-flat.vmdk trueview.vmdk
  chmod 644 ${OUTFILE}-vmdk.zip
  rm trueview-flat.vmdk
  rm trueview.vmdk

  # Save the .ova to stage server
  if [ -n "$SFTPHOST" ] ; then
    STAGE="${SFTPFINALDIR}/iso/trueview/amd64"

    echo "Moving TrueView to stage server..."
    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${STAGE}" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" /root/trueview/ ${SFTPUSER}@${SFTPHOST}:${STAGE}/
    if [ $? -ne 0 ] ; then exit_clean ; fi
  fi

  exit 0
}

jenkins_mkcustard()
{
  cd /root

  # Roll back to clean snapshot
  VBoxManage snapshot custard restore clean
  if [ $? -ne 0 ] ; then
    echo "Failed to roll-back to @clean snapshot"
    exit 1
  fi

  # Start the custard VM and wait for it to finish
  ( VBoxHeadless -s custard >/dev/null 2>/dev/null ) &
  count=0

  echo "Waiting for Custard prep to finish..."
  while :
  do
    sleep 30
    echo "."

    vboxmanage list runningvms | grep -q "custard"
    if [ $? -ne 0 ] ; then
      break
    fi

    count=`expr $count + 1`
    if [ $count -gt 20 ] ; then
      VBoxManage controlvm custard poweroff
      exit 1
    fi
  done

  rm -rf /root/custard/
  mkdir /root/custard
  OUTFILE=/root/custard/custard-`date '+%Y-%m-%d-%H-%M'`

  # Looks like custard finished on its own, lets package it up
  VBoxManage modifyvm custard --nic1 bridged
  VBoxManage modifyvm custard --nic2 bridged

  echo "Exporting CUSTARD .ova file..."
  VBoxManage export custard -o ${OUTFILE}.ova
  chmod 644 ${OUTFILE}.ova
  echo "Exporting CUSTARD legacy .ova file..."
  VBoxManage export custard -o ${OUTFILE}-legacy.ova --legacy09
  chmod 644 ${OUTFILE}-legacy.ova
  echo "Exporting CUSTARD ovf20 .ova file..."
  VBoxManage export custard -o ${OUTFILE}-ovf20.ova --ovf20
  chmod 644 ${OUTFILE}-ovf20.ova

  # Export the RAW disk image
  dimg=`ls /root/VirtualBox\ VMs/custard/custard*.vmdk`
  vboxmanage clonemedium "$dimg" /root/custard/custard.vmdk --format VMDK --variant Fixed,ESX
  cd /root/custard
  zip -r ${OUTFILE}-vmdk.zip custard-flat.vmdk custard.vmdk
  chmod 644 ${OUTFILE}-vmdk.zip
  rm custard-flat.vmdk
  rm custard.vmdk

  # Save the .ova to stage server
  if [ -n "$SFTPHOST" ] ; then
    STAGE="${SFTPFINALDIR}/iso/custard/amd64"

    echo "Moving CUSTARD to stage server..."
    ssh ${SFTPUSER}@${SFTPHOST} "mkdir -p ${STAGE}" >/dev/null 2>/dev/null
    rsync -va --delete -e "ssh -o StrictHostKeyChecking=no" /root/custard/ ${SFTPUSER}@${SFTPHOST}:${STAGE}/
    if [ $? -ne 0 ] ; then exit_clean ; fi
  fi

  exit 0
}

do_build_env_setup()
{

  # Set location of local PC-BSD build data
  PCBSDBDIR="/pcbsd"
  export PCBSDBDIR

  # Set location of local FreeNAS build data
  FNASBDIR="/$BUILDTAG"
  export FNASBDIR

  if [ -z "$BUILD" ] ; then
    echo "Missing BUILD"
    exit_clean
  fi

  if [ ! -d "${BDIR}/${BUILD}" ] ; then
    echo "Invalid BUILD dir: $BUILD"
    exit_clean
  fi

  # Source build conf and set some vars
  cd ${BDIR}/${BUILD}

  echo "$TYPE" | grep -q -e "freenas" -e "corral"
  if [ $? -eq 0 ] ; then
    BRANCH="production"
    . freenas.cfg
  else
    if [ -z "$BRANCH" ] ; then
      BRANCH="production"
    fi
    if [ -e 'trueos.cfg' ] ; then
      . trueos.cfg
    else
      . pcbsd.cfg
    fi
  fi

  # Set the variables to reference poudrire jail locations
  if [ -z "$JAILVER" ] ; then
    JAILVER="$TARGETREL"
  fi
  case $TYPE in
    jail|pkg) WORLDTREL="$JAILVER" ;;
     *) WORLDTREL="$TARGETREL" ;;
  esac
  if [ -z "$PKGVERUPLOAD" ] ; then
    PKGVERUPLOAD="$WORLDTREL"
  fi

  # Poudriere variables
  if [ "$ARCH" = "i386" ] ; then PBUILD="${PBUILD}-i386"; fi
  PJAILNAME="`echo $JAILVER | sed 's|\.||g'`"
  echo "$TYPE" | grep -q trueos
  if [ $? -eq 0 ] ; then
    PBUILD="trueos-`echo $JAILVER | sed 's|\.||g'`"
    PPKGDIR="/poud/data/packages/${PJAILNAME}-trueosports"
    PJPORTSDIR="/poud/ports/trueosports"
  else
    PBUILD="pcbsd-`echo $JAILVER | sed 's|\.||g'`"
    PPKGDIR="/poud/data/packages/${PJAILNAME}-pcbsdports"
    PJPORTSDIR="/poud/ports/pcbsdports"
  fi
  export PBUILD PJPORTSDIR PPKGDIR

  # Set the remote directory for FreeNAS Builds state
  FNSTATEDIR="${SFTPWORKDIR}/fnstate/${TARGETREL}"
  ENVSTAGE="${SFTPFINALDIR}/iso/${TARGETREL}/build_env"

  # Set the default amd64 arch
  if [ -z "$PACKAGE_ARCH" ] ; then
    PACKAGE_ARCH="amd64"
    export PACKAGE_ARCH
  fi

  # Set all the stage / work dirs
  if [ "$BRANCH" = "PRODUCTION" -o "$BRANCH" = "production" ] ; then
    PKGSTAGE="${SFTPFINALDIR}/pkg/${PKGVERUPLOAD}/${PACKAGE_ARCH}"
    ISOSTAGE="${SFTPFINALDIR}/iso/${TARGETREL}/${PACKAGE_ARCH}"
    DOCSTAGE="${SFTPFINALDIR}/doc/${TARGETREL}"
    WORKPKG="${SFTPWORKDIR}/pkg/${PKGVERUPLOAD}/${PACKAGE_ARCH}"
    WORKWORLD="${SFTPWORKDIR}/world/${WORLDTREL}/${PACKAGE_ARCH}"
  elif [ "$BRANCH" = "EDGE" -o "$BRANCH" = "edge" ] ; then
    PKGSTAGE="${SFTPFINALDIR}/pkg/${PKGVERUPLOAD}/edge/${PACKAGE_ARCH}"
    ISOSTAGE="${SFTPFINALDIR}/iso/${TARGETREL}/edge/${PACKAGE_ARCH}"
    DOCSTAGE="${SFTPFINALDIR}/doc/${TARGETREL}/edge"
    WORKPKG="${SFTPWORKDIR}/pkg/${PKGVERUPLOAD}/edge/${PACKAGE_ARCH}"
    WORKWORLD="${SFTPWORKDIR}/world/${WORLDTREL}/${PACKAGE_ARCH}"
  elif [ "$BRANCH" = "UNSTABLE" -o "$BRANCH" = "unstable" ] ; then
    PKGSTAGE="${SFTPFINALDIR}/pkg/${PKGVERUPLOAD}/unstable/${PACKAGE_ARCH}"
    ISOSTAGE="${SFTPFINALDIR}/iso/${TARGETREL}/unstable/${PACKAGE_ARCH}"
    DOCSTAGE="${SFTPFINALDIR}/doc/${TARGETREL}/unstable"
    WORKPKG="${SFTPWORKDIR}/pkg/${PKGVERUPLOAD}/unstable/${PACKAGE_ARCH}"
    WORKWORLD="${SFTPWORKDIR}/world/${WORLDTREL}/${PACKAGE_ARCH}"
  elif [ "$BRANCH" = "ENTERPRISE" -o "$BRANCH" = "enterprise" ] ; then
    PKGSTAGE="${SFTPFINALDIR}/pkg/${PKGVERUPLOAD}/enterprise/${PACKAGE_ARCH}"
    ISOSTAGE="${SFTPFINALDIR}/iso/${TARGETREL}/enterprise/${PACKAGE_ARCH}"
    DOCSTAGE="${SFTPFINALDIR}/doc/${TARGETREL}/enterprise"
    WORKPKG="${SFTPWORKDIR}/pkg/${PKGVERUPLOAD}/enterprise/${PACKAGE_ARCH}"
    WORKWORLD="${SFTPWORKDIR}/world/${WORLDTREL}/${PACKAGE_ARCH}"
  else
    echo "Invalid BRANCH"
    exit_clean
  fi
}

jenkins_iocage_tests()
{
  cd $WORKSPACE
  pwd
  make install
  sysrc -f /etc/rc.conf iocage_enable="YES"
  pytest --zpool zroot --junitxml=${WORKSPACE}/results/iocage.xml
}

jenkins_iocage_pkgs()
{
  echo "Starting iocage package build..."
  iocage/run-poudriere.sh
  exit $?
}

jenkins_iocage_pkgs_push()
{
  if [ ! -d "/outgoing/pkg/iocage" ] ; then
    echo "Missing packages to push!"
    exit 1
  fi

  # Set target locations
  scale="pcbsd@pcbsd-master.scaleengine.net"
  target="/usr/home/pcbsd/mirror/pkg/iocage"

  # Make sure remote target exists
  echo "ssh ${scale} mkdir -p ${target}"
  ssh ${scale} "mkdir -p ${target}" >/dev/null 2>/dev/null

  # Copy packages
  rsync -va --delete-delay --delay-updates -e "ssh -o StrictHostKeyChecking=no" /outgoing/pkg/iocage/ ${scale}:${target}/
  if [ $? -ne 0 ] ; then exit_clean; fi

}

# Helper script which reads some pipeline ENV settings and figures out GH PR details
populate_pr_pipeline()
{
  if [ -z "$CHANGE_ID" ] ; then return 0; fi
  if [ -z "$GH_ORG" ] ; then return 0; fi
  if [ -z "$GH_REPO" ] ; then return 0; fi
  ORG="$GH_ORG"
  PRBUILDER="$GH_REPO"

  # Fetch the details from github API
  echo "curl https://api.github.com/repos/$ORG/$PRBUILDER/pulls/$CHANGE_ID"
  curl "https://api.github.com/repos/$ORG/$PRBUILDER/pulls/$CHANGE_ID" > /tmp/jsonout.$$
  #echo "Raw GH output:"
  #cat /tmp/jsonout.$$

  ghprbTargetBranch=$(cat /tmp/jsonout.$$ | jq -r '.base.ref')
  ghprbSourceBranch=$(cat /tmp/jsonout.$$ | jq -r '.base.ref')
  ghprbCommentBody=$(cat /tmp/jsonout.$$ | jq -r '.body')
  ghprbPullLongDescription=$(cat /tmp/jsonout.$$ | jq -r '.body')
  rm /tmp/jsonout.$$

  export ghprbTargetBranch ghprbSourceBranch ghprbCommentBody ghprbbPullLongDescription
  export PRBUILDER

  export BUILDINCREMENTAL="YES"
  export ARTIFACTONFAIL=yes
  export ARTIFACTONSUCCESS=yes

  echo "Populated GitHub PR details:"
  echo "ghprbTargetBranch: $ghprbTargetBranch"
  echo "ghprbSourceBranch: $ghprbSourceBranch"
  echo "ghprbCommentBody: $ghprbCommentBody"
  echo "ghprbPullLongDescription: $ghprbPullLongDescription"

  # Something went wrong?
  if [ -z "$ghprbTargetBranch" ] ; then exit 1 ; fi
}

# Set the builds directory
BDIR="./builds"
export BDIR

# Check the type of build being done
case $TYPE in
  ports-tests) ;;
  mkcustard) ;;
  mktrueview) ;;
  iocage_pkgs|iocage_pkgs_push) ;;
  *) do_build_env_setup ;;
esac
