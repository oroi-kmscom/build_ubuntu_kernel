#!/bin/bash

#GitHub This: https://github.com/Turbine1991/build_ubuntu_kernel_wastedcores

##Includes
. functions.sh

#Detect and enable source repository when required
##Detect and add missing sources
CONTENT_APT_SOURCES=$(cat_contents "/etc/apt/sources.list")
CONTENT_APT_SOURCES_DEB=$(echo "$CONTENT_APT_SOURCES" | grep "^deb " | grep "main")
CONTENT_APT_SOURCES_SRC=$(echo "$CONTENT_APT_SOURCES" | grep "^deb-src " | grep "main")

CONTENT_APT_LINE=$(echo "$CONTENT_APT_SOURCES_DEB" | head -n 1)
CONTENT_APT_URL=$(echo "$CONTENT_APT_LINE" | awk '{ print $2 }')
CONTENT_APT_RELEASE=$(echo "$CONTENT_APT_LINE" | awk '{ print $3 }')

CONTENT_APT_SOURCES_TAGS=$(echo "$CONTENT_APT_LINE" | awk '{print substr($0, index($0,$4))}')

###Filter relevant release entries
echo "  [Your system release is '$CONTENT_APT_RELEASE' using packages from '$CONTENT_APT_URL']"

CONTENT_APT_SOURCES_DEB=$(echo "$CONTENT_APT_SOURCES_DEB" | grep "$CONTENT_APT_RELEASE" | grep "$CONTENT_APT_URL")
CONTENT_APT_SOURCES_SRC=$(echo "$CONTENT_APT_SOURCES_SRC" | grep "$CONTENT_APT_RELEASE" | grep "$CONTENT_APT_URL")

###Check for missing entries
echo "  [Detecting whether sources are enabled in '/etc/apt/sources.list']"

CONTENT_APT_BRANCHES="$CONTENT_APT_RELEASE ${CONTENT_APT_RELEASE}-updates ${CONTENT_APT_RELEASE}-backports ${CONTENT_APT_RELEASE}-security"

for branch in $CONTENT_APT_BRANCHES
do
  #Check if branch missing from deb-src which exist in deb (some people may not have other branches available)
  if [[ -z $(echo $CONTENT_APT_SOURCES_SRC | grep "$branch ") && ! -z $(echo $CONTENT_APT_SOURCES_DEB | grep "$branch ") ]]; then
    line="deb-src $CONTENT_APT_URL $branch $CONTENT_APT_SOURCES_TAGS"
    echo "  [Appending to '/etc/apt.sources.list' '$line']"
    echo "$line" >> "/etc/apt/sources.list"
  fi
done

##Download Dependencies
apt update
apt install software-properties-common

###Find latest official kernel installed, ignore custom kernels
BUILD_PREFIX=$(cat_contents "BUILD_PREFIX")
KERNEL_INSTALLED_LATEST=$(dpkg -l linux-image* | grep "^ii" | awk '{ print $2 }' | grep -v "$BUILD_PREFIX\|+" | awk 'END { print }')

###Install dependencies for existing kernel installation, ignoring any custom kernels
echo "  [Obtaining dependencies for existing kernel: '$KERNEL_INSTALLED_LATEST']"

apt build-dep "$KERNEL_INSTALLED_LATEST"
apt install curl kernel-package libncurses5-dev fakeroot wget bzip2 libssl-dev liblz4-tool git
#

{
if [[ -f "kernel/mainline-crack/.config" ]]; then
  cp "kernel/mainline-crack/.config" ./
fi

rm -R kernel
mkdir kernel
cd kernel

##Setup
KERNEL_SOURCE_URL="http://kernel.ubuntu.com/~kernel-ppa/mainline"

##Manage kernel version
#Declare
versions="daily 4.13 "

#Retrieve patch branches from git
branches=$(get_git_branches "https://github.com/Freeaqingme/wastedcores.git")
versions="$versions$branches"

#Initialise
versions_max=$(sa_get_count "$versions")

#Order
versions=$(echo "$versions" | sort -V)
#versions=$(sa_reverse "$versions")

#List kernel version choices
printf "\nKernel Versions\n"

print_choices "$versions"

#Prompt
printf "Please enter your choice: "
while read i
do
  #Check if valid input, is a number, is within choice boundaries
  if [[ -z "$i" || "$i" -ne "$i" || "$i" > "$versions_max" ]]; then
    printf "Try again: "
  else
    break
  fi
done

version=$(sa_get_value "$versions" $((i-1)))

#Process selected kernel version
if [[ $version == "daily" ]]; then
  KERNEL_VERSION="$version"

  KERNEL_SOURCE_URL="$KERNEL_SOURCE_URL/daily/current"

  PATCH_URL="$KERNEL_SOURCE_URL"
else
  KERNEL_VERSION="$version"

  ##Find latest kernel version in a specific branch
  PATCH_DIR=`get_http_apache_listing "$KERNEL_SOURCE_URL" "v$KERNEL_VERSION" 1`
  PATCH_URL="$KERNEL_SOURCE_URL/$PATCH_DIR"
fi

##Get kernel data
wget "$PATCH_URL/SOURCES"

##Retrieve patches
mkdir patch
cd patch

#Download kernel patches
while read f; do
  if [[ $f == *".patch" ]]; then
    wget "$PATCH_URL/$f"
  fi
done < "../SOURCES"

#Get kernel sorces file
#Ref: http://kernel.ubuntu.com/~kernel-ppa/mainline/daily/current/SOURCES
KERNEL_LINE=$(head -1 SOURCES)
KERNEL_GIT_URL=$(echo "$KERNEL_LINE" | awk '{ printf "%s", $1 }')
KERNEL_GIT_BRANCH=$(echo "$KERNEL_LINE" | awk '{ printf "%s", $2 }')
#

#Download other patches
mkdir patch
cd patch

PATH_PATCH=$(pwd)

##Download additional CPU optimizations patch
wget https://raw.githubusercontent.com/graysky2/kernel_gcc_patch/master/enable_additional_cpu_optimizations_for_gcc_v4.9%2B_kernel_v4.13%2B.patch
cd ..

#Download kernel source
STR_GIT_LINUX=$(echo "$KERNEL_GIT_URL $KERNEL_GIT_BRANCH" | awk '{ printf "git clone --depth 1 --branch %s %s", $2, $1 }')

echo " [Obtaining kernel sources with line: '$STR_GIT_LINUX']"

$STR_GIT_LINUX

#Move kernel directory to always me called mainline-crack (instead of branch directory structure)
OLD_KERNEL_DIR=$(dirname $(find $(pwd) -name "Makefile" -type f -print | awk ' NR==1 || length<len {len=length; line=$0} END {print line} '))

#echo "mv $OLD_KERNEL_DIR kernel/mainline-crack"
mv "$OLD_KERNEL_DIR" "mainline-crack"

#Patch source
cd "mainline-crack"

for f in $PATH_PATCH/*.patch;
do
  patch -p1 -i "$f"
done

#Patch Makefile
sed -i '/HOSTCFLAGS   =/c\HOSTCFLAGS   = -march=native -mtune=native -Ofast -fmodulo-sched -fmodulo-sched-allow-regmoves -fno-tree-vectorize -std=gnu89' Makefile
sed -i '/HOSTCXXFLAGS =/c\HOSTCXXFLAGS = -march=native -mtune=native -Ofast' Makefile

#Create the "REPORTING-BUGS" file if missing. Workaround for bug #11
touch "REPORTING-BUGS"

#Generate config prompt
read -p "Generate a localmodconfig (y/n): " -n 1
if [[ $REPLY =~ ^[Yy]$ ]]; then
  make localmodconfig
else
  make oldconfig
fi

#Disable debuging & enable expert mode
read -p "Disable kernel debugging (y/n): " -n 1
if [[ $REPLY =~ ^[Yy]$ ]]; then
  sed -i 's/# CONFIG_KALLSYMS is not set/CONFIG_EXPERT=y/g' .config
  sed -i 's/CONFIG_KALLSYMS=y/# CONFIG_KALLSYMS is not set/g' .config
  sed -i 's/CONFIG_DEBUG_KERNEL=y/# CONFIG_DEBUG_KERNEL is not set/g' .config
fi
}

if [[ $KERNEL_TARGET = "sp4" ]]; then
  sed -i '/CONFIG_INTEL_IPTS/c\CONFIG_INTEL_IPTS=m' .config
fi
