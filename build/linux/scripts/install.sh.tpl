#!/bin/bash
############################################################################ ###
#@Copyright     Copyright (c) Imagination Technologies Ltd. All Rights Reserved
#@License       MIT
# The contents of this file are subject to the MIT license as set out below.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#### ###########################################################################
# Help on how to invoke
#
function usage {
    echo "usage: $0 [options...]"
    echo ""
    echo "Options: -v            Verbose mode."
    echo "         -n            Dry-run mode."
    echo "         -u            Uninstall-only mode."
    echo "         --root <path> Use <path> as the root of the install file system."
    echo "                       (Overrides the DISCIMAGE environment variable.)"
    echo "         -p <target>   Pack mode: Don't install anything.  Just copy files"
    echo "                       required for installation to <target>." 
    echo "                       (Sets/overrides the PACKAGEDIR environment variable.)"
    echo "         --nolog       Don't produce any logfiles."
    exit 1
}

WD=`pwd`
SCRIPT_ROOT=`dirname $0`
cd $SCRIPT_ROOT

# Parse arguments
while [ "$1" ]; do
    case "$1" in
    -v|--verbose)
        VERBOSE=v
        ;;
    -r|--root)
        DISCIMAGE=$2
        shift;
        ;;
    -u|--uninstall)
        UNINSTALL_ONLY=y
        INSTALL_PREFIX="uni"
        INSTALL_PREFIX_CAP="Uni"
        ;;
    -n)
        DOIT=echo
        ;;
    -p|--package)
        PACKAGEDIR=$2
        if [ ${PACKAGEDIR:0:1} != '/' ]; then
            PACKAGEDIR=$WD/$PACKAGEDIR
        fi
        shift;
        ;;
    --nolog)
        DISABLE_LOGGING=1
        ;; 
    -h | --help | *)
        usage
        exit 0
        ;;
    esac
    shift
done

PVRVERSION=[PVRVERSION]
PVRBUILD=[PVRBUILD]
PRIMARY_ARCH="[PRIMARY_ARCH]"
ARCHITECTURES="[ARCHITECTURES]"
LWS_PREFIX=[LWS_PREFIX]
SHLIB_DESTDIR_DEFAULT=[SHLIB_DESTDIR]

BIN_DESTDIR_DEFAULT=[BIN_DESTDIR]
SHADER_DESTDIR_DEFAULT=[SHADER_DESTDIR]
FW_DESTDIR_DEFAULT=[FW_DESTDIR]
INCLUDE_DESTDIR_DEFAULT=/usr/include

RC_DESTDIR=/etc/init.d
UDEV_DESTDIR=/etc/udev/rules.d
OPENCL_ICD_CONF=/etc/OpenCL/vendors

for i in lib64 lib32 lib; do
    DEFAULT_DDX_DESTDIRS="${DEFAULT_DDX_DESTDIRS} /usr/$i/xorg/modules/drivers"
done

function set_destination_from_list() {
    local i
    local retvar=$1
    shift
    for i in $*; do 
        if [ -d ${DISCIMAGE}/$i ] ; then
            eval $retvar='$i'
            return
        fi
    done
    
    echo "WARNING: None of the destinations '$*' exist"
    echo "         Can't set '$retvar'"
}

if [ -z ${DDX_DESTDIR} ];then
    if [ "${LWS_PREFIX}" = /usr ]; then
        # Install into the standard place.
        set_destination_from_list DDX_DESTDIR ${DEFAULT_DDX_DESTDIRS}
    else
        DDX_DESTDIR=${LWS_PREFIX}/lib/xorg/modules/drivers
    fi
fi

if [ "${LWS_PREFIX}" = /usr ]; then
    # Install into the standard place.
    CONF_DESTDIR=/etc/X11
else
    CONF_DESTDIR=${LWS_PREFIX}/etc/X11
fi

if [ `echo ${ARCHITECTURES} | wc -w` -le 2 ]; then
    INSTALLING_SINGLELIB=1
fi

XORG_LOCATION=/usr/local/pvr
INSTALL_PREFIX="i"
INSTALL_PREFIX_CAP="I"

# Exit with an error messages.
# $1=blurb
#
function bail() {
    if [ ! -z "$1" ]; then
        echo "$1" >&2
    fi

    echo "" >&2
    echo $INSTALL_PREFIX_CAP"nstallation failed" >&2
    exit 1
}

# Copy the files that we are going to install into $PACKAGEDIR
function copy_files_locally() {
    # Create versions of the installation functions that just copy files to a useful place.
    function check_module_directory() { true; }
    function uninstall() { true; }
    function link_library() { true; }
    function set_icdconf()  { true; }
    function symlink_library_if_not_present() { true; }

    # basic installation function
    # $1=fromfile, $4=chmod-flags
    # plus other stuff that we aren't interested in.
    function install_file() {
        if [ -f "$1" ]; then
            $DOIT cp $1 $PACKAGEDIR/$THIS_ARCH
            $DOIT chmod $4 $PACKAGEDIR/$THIS_ARCH/$1
        fi
    }
    
    # Tree-based installation function
    # $1 = fromdir
    # plus other stuff that we aren't interested in.
    function install_tree() {
        if [ -d "$1" ]; then
            cp -Rf $1 $PACKAGEDIR/$THIS_ARCH
        fi
    }

    echo "Copying files to $PACKAGEDIR."
    
    if [ -d $PACKAGEDIR ]; then
        rm -Rf $PACKAGEDIR
    fi
    mkdir -p $PACKAGEDIR

    for THIS_ARCH in $ARCHITECTURES; do
        if [ ! -d $THIS_ARCH ]; then
            continue
        fi

        mkdir -p $PACKAGEDIR/$THIS_ARCH
        pushd $THIS_ARCH > /dev/null
        if [ -f install_um.sh ]; then
            source install_um.sh
            install_file install_um.sh x x 0644
        fi
        install_file rgxfw_debug.zip x x 0644
        popd > /dev/null
    done
    
    THIS_ARCH=$PRIMARY_ARCH
    pushd $THIS_ARCH > /dev/null
    if [ -f install_km.sh ]; then
        source install_km.sh
        install_file install_km.sh x x 0644
    fi
    popd > /dev/null

    unset THIS_ARCH
    install_file install.sh x x 0755
}

# Install the files on the remote machine using SSH
# We do this by:
#  - Copying the required files to a place on the local disk
#  - rsync these files to the remote machine
#  - run the install via SSH on the remote machine
function install_via_ssh() {
    # Default to port 22 (SSH) if not otherwise specified
    if [ -z "$INSTALL_TARGET_PORT" ]; then
        INSTALL_TARGET_PORT=22
    fi

    # Execute something on the target machine via SSH
    # $1 The command to execute
    function remote_execute() {
        COMMAND=$1
        ssh -p "$INSTALL_TARGET_PORT" -q -o "BatchMode=yes" root@$INSTALL_TARGET "$1"
    }

    if ! remote_execute "test 1"; then
        echo "Can't access $INSTALL_TARGET via ssh."
        echo "Have you installed your public key into root@$INSTALL_TARGET:~/.ssh/authorized_keys?"
        echo "If root has a password on the target system, you can do so by executing:"
        echo "ssh root@$INSTALL_TARGET \"mkdir -p .ssh; cat >> .ssh/authorized_keys\" < ~/.ssh/id_rsa.pub"
        bail
    fi

    # Create a directory to contain all the files we are going to install.
    PACKAGEDIR_PREFIX=`mktemp -d` || bail "Couldn't create local temporary directory"
    PACKAGEDIR=$PACKAGEDIR_PREFIX/Rogue_DDK_Install_Root
    PACKAGEDIR_REMOTE=/tmp/Rogue_DDK_Install_Root
    copy_files_locally

    echo "RSyncing $PACKAGEDIR to $INSTALL_TARGET:$INSTALL_TARGET_PORT."
    $DOIT rsync -crlpt -e "ssh -p \"$INSTALL_TARGET_PORT\"" --delete $PACKAGEDIR/ root@$INSTALL_TARGET:$PACKAGEDIR_REMOTE || bail "Couldn't rsync $PACKAGEDIR to root@$INSTALL_TARGET"
    echo "Running "$INSTALL_PREFIX"nstall remotely."

    REMOTE_COMMAND="bash $PACKAGEDIR_REMOTE/install.sh -r /"

    if [ "$UNINSTALL_ONLY" == "y" ]; then
	REMOTE_COMMAND="$REMOTE_COMMAND -u"
    fi

    remote_execute "$REMOTE_COMMAND" || bail "Couldn't execute install remotely."
    rm -Rf $PACKAGEDIR_PREFIX
}
    
# Copy all the required files into their appropriate places on the local machine.
function install_locally {
    # Define functions required for local installs

    # Check that the appropriate kernel module directory is there
    # $1 the module directory we are looking for
    #
    function check_module_directory {
        MODULEDIR=$1
        if [ ! -d "${DISCIMAGE}${MODULEDIR}" ]; then
            echo 
            echo "Can't find ${MODULEDIR} in the target file system."
            echo 
            echo "If you are using a custom kernel, you probably need to install the kernel"
            echo "modules." 
            echo "You can do so by executing the following:"
            echo " \$ cd \$KERNELDIR"
            echo " \$ make [ INSTALL_MOD_PATH=\$DISCIMAGE ] modules_install"
            echo "(You need to set INSTALL_MOD_PATH if your build machine is not your target"
            echo "machine.)"
            echo
            echo "If you are not using a custom kernel, ensure you KERNELDIR identifies the"
            echo "correct kernel headers.  E.g., if you are building on your target machine:"
            echo " \$ export KERNELDIR=/usr/src/linux-headers-\`uname -r\`"
            echo " \$ make [ ... ] kbuild"
            bail
        fi

        if [ -d "${DISCIMAGE}${MODULEDIR}/kernel/drivers/gpu/drm/img-rogue" ]; then
            echo 
            echo "It looks like ${MODULEDIR} in the target file system contains prebuilt versions"
            echo "of rogue drivers.  You'll need to remove these before installing locally-built"
            echo "versions.  To do so, run the following on the target system:"
            echo " \$ sudo rm -Rf ${MODULEDIR}/kernel/drivers/gpu/drm/img-rogue"
            echo "then reboot."
            bail
        fi
    }

    function setup_libdir_for_arch {
        local libdir=$1
        if [ -n "$INSTALLING_SINGLELIB" ]; then
            if [ -d ${DISCIMAGE}$libdir ]; then 
                SHLIB_DESTDIR=$libdir
            else
                SHLIB_DESTDIR=${SHLIB_DESTDIR_DEFAULT}
            fi
        else
            if [ ! -d ${DISCIMAGE}$libdir ]; then 
                bail "Library directory $libdir for architecture $arch does not exist."
            fi
            SHLIB_DESTDIR=$libdir
        fi
    }

    function setup_bindir_for_arch {
        if [ $arch = ${PRIMARY_ARCH} ]; then
            BIN_DESTDIR=${BIN_DESTDIR_DEFAULT}
        else
            BIN_DESTDIR=$1
        fi
    }
    
    function setup_dirs {
        case $1 in 
        'target_x86_64')
            setup_libdir_for_arch ${SHLIB_DESTDIR_DEFAULT}/x86_64-linux-gnu
            setup_bindir_for_arch ${BIN_DESTDIR_DEFAULT}64
            ;;
        'target_i686')
            setup_libdir_for_arch ${SHLIB_DESTDIR_DEFAULT}/i386-linux-gnu
            setup_bindir_for_arch ${BIN_DESTDIR_DEFAULT}32
            ;;
        'target_armel' | 'target_armv7-a')
            setup_libdir_for_arch ${SHLIB_DESTDIR_DEFAULT}/arm-linux-gnueabi
            setup_bindir_for_arch ${BIN_DESTDIR_DEFAULT}32
            echo $SHLIB_DESTDIR
            ;;
        'target_armv7-a')
            setup_libdir_for_arch ${SHLIB_DESTDIR_DEFAULT}
            setup_bindir_for_arch ${BIN_DESTDIR_DEFAULT}
            echo $SHLIB_DESTDIR
            ;;
        'target_armhf')
            setup_libdir_for_arch ${SHLIB_DESTDIR_DEFAULT}/arm-linux-gnueabihf
            setup_bindir_for_arch ${BIN_DESTDIR_DEFAULT}32
            echo $SHLIB_DESTDIR
            ;;
        'target_aarch64')
            setup_libdir_for_arch ${SHLIB_DESTDIR_DEFAULT}/aarch64-linux-gnu
            setup_bindir_for_arch ${BIN_DESTDIR_DEFAULT}64
            echo $SHLIB_DESTDIR
            ;;
        'target_mips32r2el')
            setup_libdir_for_arch ${SHLIB_DESTDIR_DEFAULT}/mips-linux-gnu
            setup_bindir_for_arch ${BIN_DESTDIR_DEFAULT}32
            echo $SHLIB_DESTDIR
            ;;
        'target_mips64r6el')
            setup_libdir_for_arch ${SHLIB_DESTDIR_DEFAULT}/mips64-linux-gnu
            setup_bindir_for_arch ${BIN_DESTDIR_DEFAULT}64
            echo $SHLIB_DESTDIR
            ;;
        'target_neutral' | '')
            unset SHLIB_DESTDIR
            unset BIN_DESTDIR
            unset EGL_DESTDIR
            INCLUDE_DESTDIR=${INCLUDE_DESTDIR_DEFAULT}
            SHADER_DESTDIR=${SHADER_DESTDIR_DEFAULT}
            DATA_DESTDIR=${BIN_DESTDIR_DEFAULT}
            FW_DESTDIR=${FW_DESTDIR_DEFAULT}
            return
            ;;
        *)
            bail "Unknown architecture $1"
            ;;
        esac

        EGL_DESTDIR=${SHLIB_DESTDIR}/egl
        GCEGL_DESTDIR=${SHLIB_DESTDIR}/gcegl
        if [ -z "${DRI_DESTDIR}" ]; then
            if [ "${LWS_PREFIX}" = /usr ]; then
                if [ $1 = ${PRIMARY_ARCH} ]; then
                    set_destination_from_list DRI_DESTDIR ${SHLIB_DESTDIR}/dri /usr/lib64/dri /usr/lib32/dri /usr/lib/dri
                else
                    set_destination_from_list DRI_DESTDIR ${SHLIB_DESTDIR}/dri /usr/lib32/dri /usr/lib/dri
                fi
            else
                if [ $1 = ${PRIMARY_ARCH} ]; then
                    DRI_DESTDIR=${LWS_PREFIX}/lib/dri
                else
                    DRI_DESTDIR=${LWS_PREFIX}/lib32/dri
                fi
            fi
        fi
    }
    
    # basic installation function
    # $1=fromfile, $2=destfilename, $3=blurb, $4=chmod-flags, $5=chown-flags
    #
    function install_file {
        if [ -z "$DDK_INSTALL_LOG" ]; then
            bail "INTERNAL ERROR: Invoking install without setting logfile name"
        fi
        DESTFILE=${DISCIMAGE}$2
        DESTDIR=`dirname $DESTFILE`
    
        if [ ! -e $1 ]; then
            [ -n "$VERBOSE" ] && echo "skipping file $1 -> $2"
            return
        fi
        
        # Destination directory - make sure it's there and writable
        #
        if [ -d "${DESTDIR}" ]; then
            if [ ! -w "${DESTDIR}" ]; then
                bail "${DESTDIR} is not writable."
            fi
        else
            $DOIT mkdir -p ${DESTDIR} || bail "Couldn't mkdir -p ${DESTDIR}"
            [ -n "$VERBOSE" ] && echo "Created directory `dirname $2`"
        fi
    
        # Delete the original so that permissions don't persist.
        #
        $DOIT rm -f $DESTFILE
    
        $DOIT cp -f $1 $DESTFILE || bail "Couldn't copy $1 to $DESTFILE"
        $DOIT chmod $4 ${DESTFILE}
        $DOIT chown $5 ${DESTFILE}
    
        echo "$3 `basename $1` -> $2"
        $DOIT echo "file $2" >> $DDK_INSTALL_LOG
    }


    function do_link {
        local DESTDIR=$1
        local FILENAME=$2
        local LINKNAME=$3
        pushd ${DISCIMAGE}/$DESTDIR > /dev/null
        # Delete the original so that permissions don't persist.
        $DOIT ln -sf $FILENAME $LINKNAME || bail "Couldn't link $FILENAME to $LINKNAME"
        $DOIT echo "link $DESTDIR/$LINKNAME" >> $DDK_INSTALL_LOG
        [ -n "$VERBOSE" ] && echo " linked $LINKNAME -> $FILENAME"
        popd > /dev/null
    }
    
    # Create the relevant links for the given library
    # ldconfig will do this too.
    function link_library {
        if [ -z "$DDK_INSTALL_LOG" ]; then
            bail "INTERNAL ERROR: Invoking install without setting logfile name"
        fi
    
        local TARGETFILE=`basename $1`
        local DESTDIR=`dirname $1`
    
        if [ ! -e ${DISCIMAGE}/${DESTDIR}/${TARGETFILE} ]; then
            [ -n "$VERBOSE" ] && echo "Can't link ${DISCIMAGE}${DESTDIR}/${TARGETFILE} as it doesn't exist."
            return
        fi

        local SONAME=`objdump -p ${DISCIMAGE}/${DESTDIR}/$TARGETFILE | grep SONAME | awk '{print $2}'`
        
        if [ -n "$SONAME" ]; then
          do_link $DESTDIR $TARGETFILE $SONAME
        fi

        local BASENAME=`expr match $TARGETFILE '\(.\+\.so\)'`
        
        if [ "$BASENAME" != "$TARGETFILE" ]; then
          do_link $DESTDIR $TARGETFILE $BASENAME
        fi
    }

    function set_icdconf {
        local LIBNAME=$1
        local DESTFILE=$2
        $DOIT mkdir -p ${DISCIMAGE}/`dirname ${DESTFILE}`
        $DOIT echo ${LIBNAME} > ${DISCIMAGE}/${DESTFILE}
        $DOIT echo "icdconf ${DESTFILE}" >> $DDK_INSTALL_LOG
        echo "icdconf ${LIBNAME} -> ${DESTFILE}"
    }

	function symlink_library_if_not_present {
        local DESTDIR=$1
        local LIBNAME=$2
        local DESTFILE=$3

		# Only make a symlink if the file doesn't exist
		if [ ! -e ${DISCIMAGE}/${DESTDIR}/${DESTFILE} ]; then
			do_link $DESTDIR $LIBNAME $DESTFILE
			echo "symlink ${LIBNAME} -> ${DESTFILE}"
		fi
	}


    # Tree-based installation function
    # $1 = fromdir $2=destdir $3=blurb
    #
    function install_tree {
        if [ -z "$DDK_INSTALL_LOG" ]; then
            bail "INTERNAL ERROR: Invoking install without setting logfile name"
        fi

        # Make the destination directory if it's not there
        #
        if [ ! -d ${DISCIMAGE}$2 ]; then
            $DOIT mkdir -p ${DISCIMAGE}$2 || bail "Couldn't mkdir -p ${DISCIMAGE}$2"
        fi
        if [ "$DONTDOIT" ]; then
            echo "### tar -C $1 -cf - . | tar -C ${DISCIMAGE}$2 -xm${VERBOSE}f -" 
        else
            tar -C $1 -cf - . | tar -C ${DISCIMAGE}$2 -xm${VERBOSE}f -
        fi
        if [ $? = 0 ]; then
            echo "Installed $3 in ${DISCIMAGE}$2"
            find $1 -type f -printf "%P\n" | while read INSTALL_FILE; do
                $DOIT echo "file $2/$INSTALL_FILE" >> $DDK_INSTALL_LOG
            done
            find $1 -type l -printf "%P\n" | while read INSTALL_LINK; do
                $DOIT echo "link $2/$INSTALL_LINK" >> $DDK_INSTALL_LOG
            done
        else
            echo "Failed copying $3 from $1 to ${DISCIMAGE}$2"
        fi
    }
    
    for arch in $ARCHITECTURES; do
        if [ ! -d $arch ]; then
            continue
        fi
        
        pushd $arch > /dev/null
        # Install UM components
        if [ -f install_um.sh ]; then
            setup_dirs $arch
            DDK_INSTALL_LOG=$UMLOG
            echo "Installing User components for architecture $arch"
            if [ -z "$FIRST_TIME" ] ; then
                $DOIT echo "version $PVRVERSION" > $DDK_INSTALL_LOG
            fi
            FIRST_TIME=1
            source install_um.sh
            echo 
            setup_dirs
        fi
        popd > /dev/null
    done

    pushd $PRIMARY_ARCH > /dev/null
    # Install KM components
    if [ -f install_km.sh ]; then
        DDK_INSTALL_LOG=$KMLOG
        echo "Installing Kernel components for architecture $PRIMARY_ARCH"
        $DOIT echo "version $PVRVERSION" > $DDK_INSTALL_LOG
        source install_km.sh
        echo
    fi
    popd > /dev/null

    if [ -n "${DISABLE_LOGGING}" ]; then
        # Create an OLDLOG so old versions of the driver can uninstall.
        $DOIT echo "version $PVRVERSION" > $OLDLOG
        if [ -f $KMLOG ]; then
            tail -n +2 $KMLOG >> $OLDLOG
        fi
        if [ -f $UMLOG ]; then
            tail -n +2 $UMLOG >> $OLDLOG
        fi
        
        # Make sure new logs are newer than $OLDLOG
        touch -m -d "last sunday" $OLDLOG
    fi
}

# Read the appropriate install log and delete anything therein.
function uninstall_locally {
    # Function to uninstall something.
    function do_uninstall {
        LOG=$1

        if [ ! -f $LOG ]; then
            echo "Nothing to un-install."
            return;
        fi
    
        BAD=0
        VERSION=""
        while read type data; do
            case $type in
            version)
                echo "Uninstalling existing version $data"
                VERSION="$data"
                ;;
            link|file|icdconf) 
                if [ -z "$VERSION" ]; then
                    BAD=1;
                    echo "No version record at head of $LOG"
                elif ! $DOIT rm -f ${DISCIMAGE}${data}; then
                    BAD=1;
                else
                    [ -n "$VERBOSE" ] && echo "Deleted $type $data"
                fi
                ;;
            tree) # legacy type
                if [ -d ${DISCIMAGE}$XORG_LOCATION ] ; then
                    echo "Removing Linux window system components"
                    $DOIT rm -Rf ${DISCIMAGE}$XORG_LOCATION
                fi
                ;;
            esac
        done < $1;

        if [ $BAD = 0 ]; then
            echo "Uninstallation completed."
            $DOIT rm -f $LOG
        else
            echo "Uninstallation failed!!!"
        fi
    }


    if [ -z "$OLDLOG" -o -z "$KMLOG" -o -z "$UMLOG" ]; then
        bail "INTERNAL ERROR: Invoking uninstall without setting logfile name"
    fi

    # Uninstall anything installed using the old-style install scripts.
    LEGACY_LOG=0
    if [ -f $OLDLOG ]; then
        if [ -f $KMLOG -a $KMLOG -nt $OLDLOG ]; then
            # Last install was new scheme.
            rm $OLDLOG
        elif [ -f $UMLOG -a $UMLOG -nt $OLDLOG ]; then
            # Last install was new scheme.
            rm $OLDLOG
        else
            echo "Uninstalling all components from legacy log."
            do_uninstall $OLDLOG
            LEGACY_LOG=1
            echo 
        fi
    fi

    if [ $LEGACY_LOG = 0 ]; then
        # Uninstall KM components if we are doing a KM install.
        if [ -f ${PRIMARY_ARCH}/install_km.sh -a -f $KMLOG ]; then
            echo "Uninstalling Kernel components"
            do_uninstall $KMLOG
            echo 
        fi
        # Uninstall UM components if we are doing a UM install.
        DO_UNINSTALL_UM=
        for i in ${ARCHITECTURES}; do
            if [ -f $i/install_um.sh ]; then
                DO_UNINSTALL_UM=1
            fi
        done
        if [ -n "$DO_UNINSTALL_UM" -a -f $UMLOG ]; then
            echo "Uninstalling User components"
            do_uninstall $UMLOG
            echo 
        fi
    fi
}

if [ ! -z "$PACKAGEDIR" ]; then 
    copy_files_locally $PACKAGEDIR
    echo "Copy complete!"

elif [ ! -z "$INSTALL_TARGET" ]; then
    echo $INSTALL_PREFIX_CAP"nstalling using SSH/rsync on target $INSTALL_TARGET"
    echo

    install_via_ssh

elif [ ! -z "$DISCIMAGE" ]; then

    if [ ! -d "$DISCIMAGE" ]; then
       bail "$0: $DISCIMAGE does not exist."
    fi

    echo
    echo "File system root is $DISCIMAGE"
    echo

    if [ -z ${DISABLE_LOGGING} ]; then
        OLDLOG=$DISCIMAGE/etc/powervr_ddk_install.log
        KMLOG=$DISCIMAGE/etc/powervr_ddk_install_km.log
        UMLOG=$DISCIMAGE/etc/powervr_ddk_install_um.log

        # Can't do uninstall unless we are doing logging
        uninstall_locally
    else
        OLDLOG=/dev/null
        KMLOG=/dev/null
        UMLOG=/dev/null
    fi

    if [ "$UNINSTALL_ONLY" != "y" ]; then
        if [ $DISCIMAGE == "/" ]; then
            echo "Installing PowerVR '$PVRVERSION ($PVRBUILD)' locally"
        else
            echo "Installing PowerVR '$PVRVERSION ($PVRBUILD)' on $DISCIMAGE"
        fi
        echo

        install_locally
    fi

    if [ $DISCIMAGE == "/" ]; then
        # If we've installed kernel modules, then KERNELVERSION will have been set
        # by install_km.sh
        if [ -n "$KERNELVERSION"  -a `uname -r` == "$KERNELVERSION" ]; then 
            echo "Running depmod"
            depmod
        fi
        echo "Running ldconfig"
        ldconfig
        echo $INSTALL_PREFIX_CAP"nstallation complete!"
    else
        echo "To complete "$INSTALL_PREFIX"nstall, please run the following on the target system:"
        echo "$ depmod"
        echo "$ ldconfig"
    fi

else
    bail "INSTALL_TARGET or DISCIMAGE must be set for "$INSTALL_PREFIX"nstallation to be possible."
fi
    
