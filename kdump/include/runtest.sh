#!/bin/bash
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2019 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


# Source  environment
. ../../cki_lib/libcki.sh || exit 1

K_TESTAREA="/mnt/testarea"
K_NFS="${K_TESTAREA}/KDUMP-NFS"
K_PATH="${K_TESTAREA}/KDUMP-PATH"

KDUMP_CONFIG="/etc/kdump.conf"
KDUMP_SYS_CONFIG="/etc/sysconfig/kdump"

K_TMP_DIR="${K_TESTAREA}/tmp"
K_REBOOT="${K_TMP_DIR}/KDUMP-REBOOT"
C_REBOOT="./C_REBOOT"

UPGRADE_FC_KDUMP=${UPGRADE_FC_KDUMP:-"true"}
UPGRADE_FC_CRASH=${UPGRADE_FC_CRASH:-"true"}

mkdir -p ${K_TMP_DIR}

[[ "$FAMILY" =~ [a-zA-Z]+5 ]] && IS_RHEL5=true || IS_RHEL5=false
[[ "$FAMILY" =~ [a-zA-Z]+6 ]] && IS_RHEL6=true || IS_RHEL6=false
[[ "$FAMILY" =~ [a-zA-Z]+7 ]] && IS_RHEL7=true || IS_RHEL7=false
[[ "$FAMILY" =~ [a-zA-Z]+8 ]] && IS_RHEL8=true || IS_RHEL8=false
[[ "$FAMILY" =~ Fedora ]] && IS_FC=true || IS_FC=false

if $IS_RHEL5 || $IS_RHEL6; then
    INITRD_PREFIX=initrd
else
    INITRD_PREFIX=initramfs
fi
INITRD_IMG_PATH="/boot/$INITRD_PREFIX-`uname -r`.img"

# e.g. x86_64
K_ARCH=`uname -m`

# e.g 4.18.0-74.el8
K_KVER=`uname -r | sed "s/\.$K_ARCH//"`

# debug|PAE|xen|trace|vanilla if any
K_KVARI=`echo $K_KVER | grep -Eo '(debug|PAE|xen|trace|vanilla)$'`

# .e.g kernel-2.6.32-220.el6.src.rpm
K_KSRC=`rpm -q --queryformat '%{sourcerpm}\n' -qf /boot/config-$(uname -r)`

# In RHEL-8, `uname -r` on a debug kernel returns '4.18.0-40.el8.x86_64+debug'
# Instead of '3.10.0-957.1.2.el7.x86_64.debug' as it usually is in RHEL-7
K_KVERS=`echo $K_KVER | sed "s/[.+]*$K_KVARI$//"`

# This is a little cryptic, in practice it takes the full src rpm file
# name and strips everytihng after (including) the version, leaving just
# the src rpm package name.
# Needed when the kernel rpm comes from of e.g. kernel-pegas src rpm.
K_SPEC_NAME=${K_KSRC%%-${K_KVER}*}

K_DEFAULT_PATH="/var/crash"
IS_RT_KEN=false

K_DEBUG=${K_DEBUG:-false}
K_NFSSERVER=${K_NFSSERVER:-""}
K_VMCOREPATH=${K_VMCOREPATH:-"/var/crash"}


[ "${K_ARCH}" = "ia64" ] && K_BOOT="/boot/efi/efi/redhat" || K_BOOT="/boot"


BackupKdumpConfig()
{
    [ -f "${KDUMP_CONFIG}" -a ! -f "${KDUMP_CONFIG}.bk" ] && cp "${KDUMP_CONFIG}" "${KDUMP_CONFIG}.bk"
    [ -f "${KDUMP_SYS_CONFIG}" -a ! -f "${KDUMP_SYS_CONFIG}.bk" ] && cp "${KDUMP_SYS_CONFIG}" "${KDUMP_SYS_CONFIG}.bk"
}

# back up kdump config files
BackupKdumpConfig

DisableAVCCheck()
{
  echo "Disable AVC check"
  export AVC_ERROR=+no_avc_check
}

# Disable AVC Check for all kdump tests
DisableAVCCheck

# Erase possible preceding/trailing white spaces.
Chomp()
{
    echo "$1" | sed '/^[[:space:]]*$/d;
        s/^[[:space:]]*\|[[:space:]]*$//g'
}

TurnDebugOn()
{
    if $IS_RHEL7 || $IS_RHEL8 ; then
        sed -i 's;\(/bin/sh\)$;\1 -x;' /usr/bin/kdumpctl
        sed -i 's;2>/dev/null;;g' /usr/bin/kdumpctl
    else
        sed -i 's;\(/bin/sh\);\1 -x;' /etc/init.d/kdump
    fi
}


CheckEnv()
{
    # Check test environment.
    if [ -z "${JOBID}" ]; then
        Log "Variable JOBID does not set! Assume developer mode."
        SERVERFILE="Server-$(date +%H_%j)"
        DEVMODE=true
    else
        SERVERFILE="Server-${JOBID}"
    fi
}

PrepareReboot()
{
    # IA-64 needs nextboot set.
    if [ -e "/usr/sbin/efibootmgr" ]; then
        EFI=$(efibootmgr -v | grep BootCurrent | awk '{ print $2}')
        if [ -n "$EFI" ]; then
            Log "- Updating efibootmgr next boot option to $EFI according to BootCurrent"
            efibootmgr -n $(efibootmgr -v | grep BootCurrent | awk '{ print $2}')
        elif [[ -z "$EFI" && -f /root/EFI_BOOT_ENTRY.TXT ]] ; then
            os_boot_entry=$(</root/EFI_BOOT_ENTRY.TXT)
            Log "- Updating efibootmgr next boot option to $os_boot_entry according to EFI_BOOT_ENTRY.TXT"
            efibootmgr -n $os_boot_entry
        else
            Log "- Could not determine value for BootNext!"
        fi
    fi
}

RunTest()
{
    func=$1
    local stage=$2

    warn=0
    error=0

    CheckEnv

    # Check test type.
    if [ -z "${SERVERS}" ] && [ -z "${CLIENTS}" ]; then
        # single host test
        ${func}

    elif echo "${CLIENTS}" | grep -qi "${HOSTNAME}"; then
        TEST="${TEST}/client"

        ${func}

        Log "- client finishes."

    elif echo "${SERVERS}" | grep -qi "${HOSTNAME}"; then
        TEST="${TEST}/server"

        # Do nothing.

        Log "- server finishes."

    else
        Error "Neither server nor client"
    fi

    Report $stage
}

CheckVmlinux()
{
    vmlinux="/usr/lib/debug/lib/modules/$(uname -r)/vmlinux"
    [ ! -f "${vmlinux}" ] && MajorError "vmlinux not found."
}


#  Common Log Functions/Variables.

declare -i error warn skip

Log() {
    local msg="$1"
    echo -e "$msg" | tee -a "${OUTPUTFILE}"
}

LogRun() {
    local comm="$1"
    local ret

    echo -e "# ${comm}" | tee -a "${OUTPUTFILE}"
    eval ${comm} | tee -a "${OUTPUTFILE}"
    ret=${PIPESTATUS[0]}
    echo | tee -a "${OUTPUTFILE}"
    return ${ret}
}

Skip() {
    local msg="$1"
    echo "- skip: $msg" | tee -a "${OUTPUTFILE}"
    skip=$((skip + 1))

    Report
}

Warn() {
    local msg="$1"
    echo "- warn: $msg" | tee -a "${OUTPUTFILE}"
    warn=$((warn + 1))
}

# error occurs - but won't abort recipe set
Error() {
    local msg="$1"
    echo "- error: $msg" | tee -a "${OUTPUTFILE}"
    error=$((error + 1))
}

# major error occurs - stop current test task and proceed to next test task.
# do not abort recipe set
MajorError() {
    local msg="$1"
    echo "- major error: $msg" | tee -a "${OUTPUTFILE}"
    error=$((error + 1))

    Report
}

# fatal error occurs - must abort recipe set
FatalError() {
    local msg="$1"

    [ -n "$msg" ] &&
    echo "- fatal error: $msg" | tee -a "${OUTPUTFILE}"
    echo "- fatal error: aborting the recipe set." | tee -a "${OUTPUTFILE}"

    error=$((error + 1))
    rstrnt-report-result "${TEST}" "FAIL" "${error}"
    rstrnt-abort -t recipeset
}

Report() {
    local stage="$1"
    local code

    if (( skip != 0 )); then
        result="SKIP"
        code=0
    elif (( error != 0 )); then
        result="FAIL"
        code=${error}
    elif (( warn != 0 )); then
        result="WARN"
        code=${warn}
    else
        result="PASS"
        code=0
    fi

    #reset codes to avoid propogating them
    error=0
    warn=0
    skip=0

    if [ -n "${stage}" ]; then
        rstrnt-report-result "${TEST}/${stage}" "${result}" "${code}"
    else
        rstrnt-report-result "${TEST}" "${result}" "${code}"
        exit 0
    fi
}

RstrntSubmit() {
    local size
    size=$(wc -c < "$1")
    # zip and upload the zipped file if the size of which is larger than 100M
    if [ "$size" -ge 100000000 ]; then
        Log "- Size of File $1 is larger than 100M. Uploading the zipped file."
        zip "${1}.zip" "${1}"
        rstrnt-report-log -l "${1}.zip"
    else
        rstrnt-report-log -l "${1}"
    fi
}

SafeReboot() {
    # It will config BootNext to be same as current boot for EFI boot machine.
    rstrnt-reboot
}


GetBiosInfo()
{
    # Get BIOS information.
    rpm -q dmidecode || InstallPackages dmidecode
    which dmidecode && {
        dmidecode >"${K_TMP_DIR}/bios.output"
        RstrntSubmit "${K_TMP_DIR}/bios.output"
    }
}

GetHWInfo()
{
    Log "- Getting system hw or firmware config."
    rpm -q lshw || InstallPackages lshw
    lshw > "${K_TMP_DIR}/lshw.output"
    RstrntSubmit "${K_TMP_DIR}/lshw.output"

    which lscfg && {
        lscfg > "${K_TMP_DIR}/lscfg.output"
        RstrntSubmit "${K_TMP_DIR}/lscfg.output"
    }
}

ReportSystemInfo()
{
    [[ "${K_ARCH}" =~ i.86|x86_64 ]] && GetBiosInfo
    GetHWInfo
}

ClearReport()
{
    rm -rf ${K_TMP_DIR}
}


#  Common Kdump/Crash Functions

# Install/Upgrade Kexec-tools and related packages
PrepareKdump()
{
    rpm -q kexec-tools || {
        # On Fedora, kexec-tools is not installed by default.
        # Install kexec-tools and enable kdump service.
        InstallPackages kexec-tools
        systemctl enable kdump.service || chkconfig kdump on

        # Back up configurations if kexec-tools is installed for the first time
        BackupKdumpConfig
    }

    # Try upgrading kexec-tools to the latest version if on FC.
    # If it fails, still use the kexec-tools from the default repo.
    if $IS_FC && $UPGRADE_FC_KDUMP; then
        UpgradePackages kexec-tools dracut systemd --enablerepo=updates-testing --enablerepo=fedora --releasever=33
    fi
}

# Install/Upgrade Crash and related packages
PrepareCrash()
{
    Log "- Installing crash and kernel-debuginfo packages required for testing crash untilities."
    rpm -q crash || InstallPackages crash
    # Try upgrading crash to the latest version if on FC.
    # If it fails, still use the crash from the default repo.
    if $IS_FC && $UPGRADE_FC_CRASH; then
        UpgradePackages crash --enablerepo=updates-testing --enablerepo=fedora --releasever=33
    fi
    InstallDebuginfo
}

# Config kernel options and make sure Kdump is operational
SetupKdump()
{
    if [ ! -f "${K_REBOOT}" ]; then
        PrepareKdump

        local default=/boot/vmlinuz-`uname -r`
        [ ! -s "$default" ] && default=/boot/vmlinux-`uname -r`

        # For uncompressed kernel, i.e. vmlinux
        [[ ${default} == *vmlinux* ]] && {
            Log "- Modifying /etc/sysconfig/kdump properly for 'vmlinux'."
            sed -i 's/\(KDUMP_IMG\)=.*/\1="vmlinux"/' /etc/sysconfig/kdump
        }

        # For kernel-rt
        $IS_RT_KEN && [ -f /usr/bin/rt-setup-kdump ] && {
            Log "- Modifying /etc/sysconfig/kdump properly for RT."
            set -x; /usr/bin/rt-setup-kdump -g; set +x
        }

        # Ensure Kdump Kernel memory reservation
        grep -q 'crashkernel' <<< "${KER1ARGS}" || {
            local kdumpMem=$(DefKdumpMem)
            [ -z "${KER1ARGS}" ] || kdumpMem=" ${kdumpMem}"

            $IS_RHEL5 && KER1ARGS+="${kdumpMem}" || {
                # memory >= auto-threshold and kdump already default on
                [ `cat /sys/kernel/kexec_crash_size` -eq 0 ] && {
                    Log "`grep MemTotal /proc/meminfo`"
                    KER1ARGS+="${kdumpMem}"
                }
            }
        }
        [ "${KER1ARGS}" ] && {
            touch "${K_REBOOT}"

            # Kdump service will not be enabled if crashkernel=auto && system
            # memory is less the threshold required by kdump service.
            /bin/systemctl enable kdump.service || /sbin/chkconfig kdump on
            rpm -q --quiet grubby || InstallPackages grubby
            Log "- Changing boot loader."
            {
                /sbin/grubby                     \
                    --args="${KER1ARGS}"         \
                    --update-kernel="${default}" &&
                if [ "${K_ARCH}" = "s390x" ]; then zipl; fi
            } || FatalError "Error changing boot loader."

            Report 'pre-reboot'
            Log "- Rebooting\n"; sync; SafeReboot
        }
    fi

    Log "- kexec-tools/systemd/dracut kernel versions"
    rpm -q kexec-tools systemd dracut kernel

    Log "- Crashkernel reservation and current cmdline"
    rpm -q lshw || InstallPackages lshw
    echo "Total system memory: $(lshw -short | grep -i "System Memory" | awk '{print $3}')"
    cat /proc/cmdline
    kdumpctl showmem || cat /sys/kernel/kexec_crash_size
    grep "fadump=on" /proc/cmdline && dmesg | grep "firmware-assisted dump" | grep "Reserved"
    [ -f "${K_REBOOT}" ] && rm -f "${K_REBOOT}"

    # Make sure kdump service fully up after a boot
    # If kdump service is not started yet, wait for max 5 mins.
    # It may take time to start kdump service.
    Log "- Waiting for kdump service to be fully up"
    local kdump_status=off
    for i in {1..5}
    do
        kdumpctl status 2>&1 || service kdump status 2>&1
        [ $? -eq 0 ] && {
            kdump_status=on
            break
        }
        sleep 60
    done
}

DefKdumpMem()
{
    local args=""

    if $IS_RHEL6; then
        if   [[ "${K_ARCH}" == i?86     ]]; then args="crashkernel=128M"
        elif [[ "${K_ARCH}"  = "x86_64" ]]; then args="crashkernel=128M"
        elif [[ "${K_ARCH}"  = "ppc64"  ]]; then args="crashkernel=256M"
        elif [[ "${K_ARCH}"  = "s390x"  ]]; then args="crashkernel=128M"
        fi

    elif $IS_RHEL7; then
        if   [[ "${K_ARCH}"  = "x86_64" ]]; then args="crashkernel=160M"
        elif [[ "${K_ARCH}"  = "s390x"  ]]; then args="crashkernel=160M"
        elif [[ "${K_ARCH}"  = ppc64*  ]]; then
            args="crashkernel=0M-4G:384M,4G-16G:512M,16G-64G:1G,64G-128G:2G,128G-:4G"
        elif [[ "${K_ARCH}"  = "aarch64"  ]]; then args="crashkernel=512M"
        fi

    elif $IS_RHEL8 || $IS_FC; then
        if   [[ "${K_ARCH}"  = "x86_64" ]]; then args="crashkernel=0M-64G:160M,64G-1T:256M,1T-:512M"
        elif [[ "${K_ARCH}"  = "s390x"  ]]; then args="crashkernel=0M-64G:160M,64G-1T:256M,1T-:512M"
        elif [[ "${K_ARCH}"  = ppc64*  ]]; then
            args="crashkernel=0M-4G:384M,4G-16G:512M,16G-64G:1G,64G-128G:2G,128G-:4G"
        elif [[ "${K_ARCH}"  = "aarch64"  ]]; then args="crashkernel=512M"
        fi

    elif $IS_RHEL5; then
        if   [[ "${K_ARCH}" == i?86     ]]; then args="crashkernel=128M@16M"
        elif [[ "${K_ARCH}"  = "x86_64" ]]; then args="crashkernel=128M@16M"
        elif [[ "${K_ARCH}"  = "ppc64"  ]]; then args="crashkernel=256M@32M xmon=off"
        elif [[ "${K_ARCH}"  = "ia64"   ]]; then args="crashkernel=512M@256M";
            # the larger IA-64 box, the more kdump memory needed
            grep -qE '^ACPI:.*(rx8640|SGI)' /var/log/dmesg &&
            args="crashkernel=768M@256M"
        fi
    fi

    echo "$args"
}

ResetKdumpConfig()
{
    Log "- Reset to default kdump config"
    echo >"${KDUMP_CONFIG}"
    echo "path /var/crash" >>"${KDUMP_CONFIG}"
    echo "core_collector makedumpfile -l --message-level 1 -d 31" >>"${KDUMP_CONFIG}"
}


TriggerSysrqPanic()
{
    touch "${C_REBOOT}"
    sync;sync;sync

    PrepareReboot

    Log "- Triggering crash."
    echo 1 > /proc/sys/kernel/sysrq
    echo c > /proc/sysrq-trigger

    sleep 60
    Error "- Failed to trigger crash after waiting for 60s."
}

AppendConfig()
{
    Log "- Modifying /etc/kdump.conf"

    if [ $# -eq 0 ]; then
        Warn "Nothing to append."
        return 0
    fi

    while [ $# -gt 0 ]; do
        Log "- Removing existed old ${1%%[[:space:]]*} settings."
        sed -i "/^${1%%[[:space:]]*}/d" ${KDUMP_CONFIG}
        Log "- Adding new '$1'."
        echo "$1" >>"${KDUMP_CONFIG}"
        shift
    done

    RstrntSubmit "${KDUMP_CONFIG}"
}


AppendSysconfig()
{
    Log "- Modifying /etc/sysconfig/kdump"

    local KEY=$1
    local ACTION=$2
    local VALUE1=$3
    local VALUE2=$4

    if [ -z "$KEY" ] || [ -z "$ACTION" ] || [ -z "$VALUE1" ]; then
        Error "- Missing KEY or ACTION or VALUE1."
        return 1
    elif [ "$ACTION" = "replace" ] && [ -z "$VALUE2" ]; then
        Error "- Missing new_value for replacing."
        return 1
    elif ! grep "^$KEY=\"" "${KDUMP_SYS_CONFIG}"; then
        Error "- Invalid KEY: $KEY."
        return 1
    fi

    local kdump_sys_config_tmp="${KDUMP_SYS_CONFIG}.tmp"
    \cp "${KDUMP_SYS_CONFIG}" "${kdump_sys_config_tmp}"

    # Note: When KEY is "KDUMP_COMMANDLINE", ACTION add/remove/replace is actually
    # manipulating the value of current kernel cmdline and assign
    # it to KDUMP_COMMANDLINE.
    # if there is no value set to KDUMP_COMMANDLINE, assign current kernel cmdline
    # to it for later string manipluation.
    if [ "$KEY" == "KDUMP_COMMANDLINE" ] && \
        grep "^$KEY=[\ \"]*$" "${kdump_sys_config_tmp}"; then

        sed -i "/^KDUMP_COMMANDLINE=\"/d" "${kdump_sys_config_tmp}"
        echo "KDUMP_COMMANDLINE=\"$(cat /proc/cmdline)\"" >> "${kdump_sys_config_tmp}"
    fi

    case $ACTION in
        add)
            # Check if the key already has a value on it, then append " $VALUE1" to the
            # original value.
            Log "- Add '$VALUE1' to '$KEY'"
            if grep -q "^$KEY=[\ \"]*$" "${kdump_sys_config_tmp}"; then
                sed -i /^"$KEY="/d "${kdump_sys_config_tmp}"
                echo "$KEY=\"$VALUE1\"" >> "${kdump_sys_config_tmp}"
            else
                sed -i "/^$KEY=/s/\"/\"$VALUE1 /" "${kdump_sys_config_tmp}"
            fi
            ;;
        remove)
            Log "- Remove '$VALUE1' from '$KEY'"
            sed -i  "/^$KEY=/s/$VALUE1//g" "${kdump_sys_config_tmp}"
            ;;
        replace)
            Log "- Replace '$VALUE1' with '$VALUE2' for '$KEY'"
            sed -i  "/^$KEY=/s/$VALUE1/$VALUE2/g" "${kdump_sys_config_tmp}"
            ;;
        override)
            Log "- Set '$VALUE1' to '$KEY'"
            sed -i "/^$KEY=\"/d" "${kdump_sys_config_tmp}"
            echo "$KEY=\"$VALUE1\"" >> "${kdump_sys_config_tmp}"
            ;;
        *)
            Error "Invalid action '${ACTION}' for editing kdump sysconfig."
            false
            ;;
    esac

    [ $? -ne 0 ] && {
        Error "- Failed to edit kdump sysconfig"
        rm -f "${kdump_sys_config_tmp}"
        return 1
    }

    \mv "${kdump_sys_config_tmp}" "${KDUMP_SYS_CONFIG}"
    RstrntSubmit "${KDUMP_SYS_CONFIG}"
    sync;sync;sync # best try to make sure the configs written to disk before panic
    return 0
}

ReportKdumprd()
{
    Log "- Reporting kdump rd image"
    if $IS_RHEL5 || $IS_RHEL6; then
        tmp=initrd
    else
        tmp=initramfs
    fi

    # Submit Kdump initramfs.
    if grep -q "fadump=on" < /proc/cmdline; then
        kdumprd=${K_BOOT}/$tmp-$(uname -r).img
    else
        kdumprd=${K_BOOT}/$tmp-$(uname -r)kdump.img
    fi

    if [ -f "${kdumprd}" ]; then
        RstrntSubmit "${kdumprd}"
    else
        Error '- No ĸdumprd generated!'
    fi

    sync
}

# print out kdump status
# no error handling
CheckKdumpStatus()
{
    kdumpctl status || service kdump status || systemctl status kdump
}

RestartKdump()
{
    local tmp=""
    local kdumprd=""
    local rc=
    local UPLOADRD=${1:-"false"}

    Log "- Restarting Kdump service."

    rm -f /boot/initrd-*kdump.img
    rm -f /boot/initramfs-*kdump.img    # For RHEL7
    touch "${KDUMP_CONFIG}"
    RstrntSubmit "${KDUMP_CONFIG}"

    if $IS_RHEL5 || $IS_RHEL6; then
        tmp=initrd
        /sbin/service kdump restart 2>&1 | tee /tmp/kdump_restart.log
        /sbin/service kdump status  2>&1
    else
        tmp=initramfs
        /usr/bin/kdumpctl showmem 2>&1
        /usr/bin/kdumpctl restart 2>&1 | tee /tmp/kdump_restart.log
        /usr/bin/kdumpctl status  2>&1
    fi
    rc=$?
    Log "`cat /tmp/kdump_restart.log`"
    [ $rc -ne 0 ] && FatalError 'Restarting kdump failed.'
    sync; sync; sleep 10

    # It may report "No kdump initial ramdisk found.[WARNING]" in rhel6
    local skip_pat="No kdump initial ramdisk found|Warning: There might not be enough space to save a vmcore|Warning no default label"
    if grep -v -E "$skip_pat" /tmp/kdump_restart.log |  grep -i -E "can't|error|warn";  then
        Warn 'Restarting kdump reported warn/error message'
    fi
    sync;

    if [ "${UPLOADRD}" == true ]; then
        ReportKdumprd
    fi
}


InstallPackages()
{
    [ $# -eq 0 ] && return 1
    local pkg=$@

    if which dnf; then
        dnf install -y $pkg
    elif which yum; then
        yum install -y $pkg
    else
        return 1
    fi

    return 0
}

UpgradePackages()
{
    [ $# -eq 0 ] && return 1
    local pkg=$@

    if which dnf; then
        dnf upgrade -y $pkg
    elif which yum; then
        yum upgrade -y $pkg
    else
        return 1
    fi

    return 0
}

InstallDebuginfo()
{
    local kern=$(rpm -qf /boot/vmlinuz-$(uname -r) --qf "%{name}-debuginfo-%{version}-%{release}.%{arch}" | sed -e "s/-core//g")
    if [[ "$kern" == *"is not owned by any package" ]]; then
        Log "- Kernel is installed from a tar, not from yum/dnf package."
        Log "- kernel-debuginfo should be prepared in cki boot test."
        Log "- Check if /usr/lib/debug/lib/modules/$(uname -r)/vmlinux exists"
        [ -f "/usr/lib/debug/lib/modules/$(uname -r)/vmlinux" ] || {
            Log "- Failed to find /usr/lib/debug/lib/modules/$(uname -r)/vmlinux."
            Log "- Warn: Skip running crash utitlies against the vmcore."
            return 1
        }
        return 0
    fi
    #workaround the kernel name if it's kernel-core
    if [[ "$kern" == kernel-core-debuginfo-* ]]; then
        kern=${kern//kernel-core/kernel}
    fi

    Log "- Installing ${kern}"
    rpm -q ${kern} || {
        InstallPackages ${kern}
        rpm -q ${kern} || {
            Log "- Failed to install ${kern}"
            Log "- Warn: Skip running crash utitlies against the vmcore."
            return 1
        }
    }
    Log "- Done installation of crash and kernel-debuginfo packages"
    Log "$(rpm -q crash ${kern})"
}

LsCore()
{
    Log "\n# ls -l ${vmcore}"
    ls -l "${vmcore}" >>"${OUTPUTFILE}" 2>&1
    [ $? -ne 0 ] && FatalError "ls returns errors."
    Log "\n"
}

GetCorePath()
{
    local path
    [ -f "${K_PATH}" ] && path=`cat "${K_PATH}"` || path="${K_DEFAULT_PATH}"
    if [ -f "${K_NFS}" ]; then
        corepath="$(cat "${K_NFS}")${path}"
    else
        corepath="${path}"
    fi

    # debug use
    Log "# find ${corepath}"
    find "${corepath}" 2>&1 | tee -a "${OUTPUTFILE}"
    Log "\n# ls -tl ${corepath}/*/"
    ls -tl "${corepath}"/*/ 2>&1 | tee -a "${OUTPUTFILE}"

    # Always analyse the latest vmcore.
    if ls -t "${corepath}"/*/vmcore; then
        vmcore=$(ls -t "${corepath}"/*/vmcore 2>/dev/null | head -1)
        return 0
    else
        Error "no vmcore found in ${corepath}"
        return 1
    fi
}

CrashCommand()
{
    local args=$1; shift
    local aux=$1; shift
    local core=$1; shift
    # allow passing cmd file other than default crash.cmd or crash-simple.cmd
    local cmd_file=$1; shift

    local result=0
    CrashCommand_CheckReturnCode "${args}" "${aux}" "${core}" "${cmd_file}" || result=1
}

# Run crash cmd defined in $cmd_file. Only return code is checked.
# Output:
#   ${cmd_file%.*}.log if on a live system
#   ${cmd_file%.*}.vmcore.log if on a vmcore
CrashCommand_CheckReturnCode()
{
    local args=$1; shift
    local aux=$1; shift
    local core=$1; shift
    local cmd_file=${1:-"crash-simple.cmd"}; shift
    local log_suffix
    [ -z "$core" ] && log_suffix=log || log_suffix="${core##*/}.log"

    Log "- Only check the return code of this session."
    Log "# crash ${args} -i ${K_TESTAREA}/${cmd_file} ${aux} ${core}"

    if [ -f "${K_TESTAREA}/${cmd_file}" ]; then
        crash ${args} -i "${K_TESTAREA}/${cmd_file}" ${aux} ${core} \
                > "${K_TESTAREA}/${cmd_file%.*}.$log_suffix" 2>&1 <<EOF
EOF
        code=$?

        echo | tee -a "${OUTPUTFILE}"
        RstrntSubmit "${K_TESTAREA}/${cmd_file%.*}.$log_suffix"
        RstrntSubmit "${K_TESTAREA}/${cmd_file}"

        if [ ${code} -eq 0 ]; then
            return 0
        else
            Error "crash returns error code ${code}."
            return 1
        fi

    fi
}

RemoveVmcores()
{
    local path
    # Do not remove anything if it's a NFS kdump target
    [ ! -f "${K_NFS}" ] && {
        if [ -f "${K_PATH}" ]; then
            path=$(cat "${K_PATH}")
        else
            path=${K_DEFAULT_PATH}
        fi

        if [ -d "${path}" ]; then
            Log "- Remove all files in ${path}"
            rm -rf "${path}"/*
        fi
    }
}

RestoreKdumpConfig()
{
    # If nfs kdump is configured, unmount the kdump nfs target
    [ -f "${K_NFS}" ] && {
        path=$(cat "${K_NFS}")
        umount "${path}"
    }

    rm -f "${K_NFS}" "${K_PATH}"

    Log "- Restore /etc/kdump.conf"
    echo > "${KDUMP_CONFIG}"
    [ -f "${KDUMP_CONFIG}.bk" ] && \cp -f "${KDUMP_CONFIG}.bk" "${KDUMP_CONFIG}"

    Log "- Restore /etc/sysconfig/kdump"
    [ -f "${KDUMP_SYS_CONFIG}.bk" ] && \cp -f "${KDUMP_SYS_CONFIG}.bk" "${KDUMP_SYS_CONFIG}"
}

# TestCleanup
# - Restore Kdump default configurations
# - Clean up vmcores
Cleanup(){
    RemoveVmcores
    RestoreKdumpConfig
}
