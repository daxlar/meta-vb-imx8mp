#!/bin/bash
set -x

BUILD_DESKTOP="yes"
SETTAG="head"
BRANCH=imx-5.15.32-vb
dobranch=0

S3BUCKET="vb-files"
S3BASE="fra1.digitaloceanspaces.com"

while getopts "k:it:c:sb:" opt; do
	case "$opt" in
		i) BUILD_DESKTOP="no"
			;;
		k) SSHKEY=$OPTARG
			;;
		t) SETTAG=$OPTARG
			;;
		b) BRANCH=$OPTARG && dobranch=1
			;;
		c) DST=$OPTARG
			;;
		s) S3="yes"
			;;
	esac
done

if [ x"$BUILD_DESKTOP" = "xyes" ]; then
    MANIFEST="imx-5.15.32-2.0.0_desktop.xml"
    DISTRO="imx-desktop-xwayland"
    SETUP="imx-setup-desktop.sh"
    IMGNAME="imx-image-desktop"
    BUILDRECIPES="imx-image-desktop navq-install-desktop imx-image-desktop-ros"
    BUILDDIR="build-desktop"
    BBMASK=""
else
    MANIFEST="imx-5.15.32-2.0.0.xml"
    DISTRO="fsl-imx-xwayland"
    IMGNAME="imx-image-full"
    BUILDRECIPES="imx-image-full navq-install"
    SETUP="imx-setup-release.sh"
    BUILDDIR="build-image"
    BBMASK=" imx-image-desktop "
fi

function cleanup() {
	eval $(ssh-agent -k)
}

if [ -f "$SSHKEY" ]; then
	eval $(ssh-agent)
	ssh-add $SSHKEY
	trap cleanup EXIT
fi

# make sure cache writes have w other access
# see also BB_DEFAULT_UMASK below
# umask 0000
umask 0002


BUILD=`date +%Y%m%d.%H%M`; start=`date +%s`
#git config --global user.email "kent@emcraft.com"
#git config --global user.name "Kent Meyer"


mkdir -p $BUILDDIR
cd $BUILDDIR

repo init -u https://source.codeaurora.org/external/imx/imx-manifest -b imx-linux-kirkstone -m ${MANIFEST} || exit $?
repo sync || exit $?

# allow build to not prompt for input
sed 's/more\ -d/\#more\ -d/' setup-environment > x && mv -f x setup-environment || exit $?

get_yocto_hash() {
	local githash=$(git rev-parse --short=10 HEAD)
	echo "$githash"
}

get_yocto_info() {
	local githash=$(get_yocto_hash)
	local val=$(echo "yocto-distro aarch64 x.x.x+git0+$githash-r0")
	echo "$val"
}

mkdir tmp
pushd tmp

for i in u-boot-imx linux-imx meta-vb-imx8mp; do
    if [ -d ${i} ]; then
	pushd ${i}
	if [ $dobranch -eq 1 ] && [ "x$(git branch --show-current)" != "x$BRANCH" ]; then
	    git checkout $BRANCH || git checkout -b $BRANCH origin/$BRANCH || exit $?
	    git pull
	fi
	popd
    else
	git clone -b $BRANCH git@github.com:daxlar/${i}.git || exit $?
    fi
    pushd $i
    if [ $i = "meta-vb-imx8mp" ]; then
	yocto_hash=$(get_yocto_hash)
	yocto_info=$(get_yocto_info)
    fi
    if [ "$SETTAG" != "head" ]; then
	if [ -z $(git tag -l $SETTAG) ]; then
	    echo "Set tag $SETTAG to $i"
	    git tag $SETTAG || exit $?
	    git push origin $SETTAG || exit $?
	    echo "Pushed tag $SETTAG"
	fi
	git checkout $SETTAG || exit $?
    fi
    popd
done

popd # tmp

pushd sources
rm -f meta-vb-imx8mp && ln -s ../tmp/meta-vb-imx8mp . || exit $?
git clone -b kirkstone https://github.com/sbabic/meta-swupdate.git
# add meta-ros here for non-desktop builds
if [ x"$BUILD_DESKTOP" = "xno" ]; then
	git clone https://github.com/daxlar/meta-ros.git
fi
popd # sources
RELEASE_VER="${SETTAG}-$(date +%m%d%H%M)-${yocto_hash}"

DISTRO=${DISTRO} MACHINE=imx8mpnavq EULA=yes BUILD_DIR=builddir source ./${SETUP} || exit $?

# set number of build threads
echo "BB_NUMBER_THREADS = \"11\"" >> conf/local.conf || exit $?
echo "PARALLEL_MAKE = \"-j 11 \"" >> conf/local.conf || exit $?

sed -i 's/^DL_DIR.*$/DL_DIR\ \?=\ \"\${PWD}\/cache\/CACHE\/5.15.32\/downloads\/\"/' conf/local.conf || exit $?
echo "SSTATE_DIR = \"${PWD}/cache/CACHE/5.15.32/sstate-cache\"" >> conf/local.conf || exit $?
echo "IMAGE_INSTALL:append = \" navq-files \"" >> conf/local.conf || exit $?
echo "BBMASK += \"$BBMASK\"" >> conf/local.conf || exit $?
sed -i -e "s/BB_DEFAULT_UMASK =/BB_DEFAULT_UMASK ?=/" ../sources/poky/meta/conf/bitbake.conf
sed -i -e "s/PACKAGE_CLASSES = \"package_rpm\"/PACKAGE_CLASSES ?= \"package_rpm\"/" conf/local.conf
sed -i -e "s/PACKAGE_CLASSES = \"package_deb\"/PACKAGE_CLASSES ?= \"package_deb\"/" conf/local.conf

# add meta-ros to bblayers for non-desktop builds
if [ x"$BUILD_DESKTOP" = "xno" ]; then
	echo BBLAYERS += \"\${BSPDIR}/sources/meta-ros/meta-ros-common\" >> conf/bblayers.conf || exit $?
	echo BBLAYERS += \"\${BSPDIR}/sources/meta-ros/meta-ros2\" >> conf/bblayers.conf || exit $?
	echo BBLAYERS += \"\${BSPDIR}/sources/meta-ros/meta-ros2-foxy\" >> conf/bblayers.conf || exit $?
fi

if [ x"$BUILD_DESKTOP" = "xyes" ]; then
	echo "APTGET_ADD_USERS = \"root::/bin/bash\"" >> conf/local.conf || exit $?
fi
echo BBLAYERS += \"\${BSPDIR}/sources/meta-vb-imx8mp\" >> conf/bblayers.conf || exit $?
echo BBLAYERS += \"\${BSPDIR}/sources/meta-swupdate\" >> conf/bblayers.conf || exit $?

echo $RELEASE_VER > ${BUILDDIR}/../sources/meta-vb-imx8mp/recipes-fsl/images/files/vb-release || exit $?

for i in ${BUILDDIR}/../sources/meta-vb-imx8mp/recipes-bsp/u-boot/u-boot-imx_2022.04.bbappend \
	 ${BUILDDIR}/../sources/meta-vb-imx8mp/recipes-kernel/linux/linux-imx_5.15.bbappend;
do
    sed -i "s/LOCALVERSION.*/LOCALVERSION = \"-${RELEASE_VER}\"/" ${i}
    if [ "x$(grep LOCALVERSION ${i})" = "x" ]; then
	echo "LOCALVERSION = \"-$RELEASE_VER\"" >> ${i} || exit $?
    fi
done

if [ "$SETTAG" != "head" ]; then
        echo "# Autogenerated, don't edit" > conf/site.conf
        pushd ../tmp/u-boot-imx;hash=$(git show-ref -s $SETTAG);popd
        echo "# Use hash for tag $SETTAG" >> conf/site.conf
        echo "SRCREV:pn-u-boot-imx = \"$hash\"" >> conf/site.conf
        echo "# Use hash for tag $SETTAG" >> conf/site.conf
        pushd ../tmp/linux-imx;hash=$(git show-ref -s $SETTAG);popd
        echo "SRCREV:pn-linux-imx = \"$hash\"" >> conf/site.conf
else
        if [ $dobranch -eq 1 ]; then
            echo "# Autogenerated, don't edit" > conf/site.conf
            pushd ../tmp/u-boot-imx;hash=$(git rev-parse origin/$BRANCH);popd
            echo "# Use hash for branch origin/$BRANCH" >> conf/site.conf
            echo "SRCREV:pn-u-boot-imx = \"$hash\"" >> conf/site.conf
            echo "# Use hash for branch origin/$BRANCH" >> conf/site.conf
            pushd ../tmp/linux-imx;hash=$(git rev-parse origin/$BRANCH);popd
            echo "SRCREV:pn-linux-imx = \"$hash\"" >> conf/site.conf
	fi
fi

#devtool modify u-boot-imx
#devtool modify linux-imx

export BB_ENV_PASSTHROUGH_ADDITIONS="PACKAGE_CLASSES"
bitbake uuu-native -c cleansstate
bitbake ${BUILDRECIPES} uuu-native || exit $?
# Only builds with package_ipk
PACKAGE_CLASSES="package_ipk" bitbake navq-swu || exit $?

echo "$yocto_info" >> $BUILDDIR/tmp/deploy/images/imx8mpnavq/$IMGNAME-imx8mpnavq.manifest || exit $?

files=(
	Image
	imx8mp-navq.dtb
	imx-boot-imx8mpnavq-sd.bin-flash_evk
	imx-image-desktop-imx8mpnavq.tar.bz2
	imx-image-desktop-imx8mpnavq.wic.bz2
	imx-image-full-imx8mpnavq.tar.bz2
	imx-image-full-imx8mpnavq.wic.bz2
	uuu
	navq-dbg.uuu
	navq-install-desktop.uuu
	navq-install.uuu
	navq-install-initrd.uImage
	navq-install-desktop-initrd.uImage
	partitions.sfdisk
)

ros_files=(
	imx-image-desktop-ros-imx8mpnavq.wic.bz2
)

# copy artifacts
if [ -d "$DST" ]; then
	mkdir -p $DST/$RELEASE_VER
	for i in ${files[*]} ${ros_files[*]}; do
		file=$BUILDDIR/tmp/deploy/images/imx8mpnavq/$i
		if [ -f $file ]; then
			cp $file $DST/$RELEASE_VER/
		fi
	done
fi

# upload a file to S3 storage
# parameters: <source> <path>
upload_to_s3() {
	# option -F would follow symlinks
	if s3cmd -F put $1 s3://${S3BUCKET}/$2/$3; then
		echo "Uploaded to https://${S3BUCKET}.${S3BASE}/$2/$3"
		s3cmd setacl --acl-public s3://${S3BUCKET}/$2/$3
	else
		echo "Error uploading $(basename $1) to s3://${S3BUCKET}/$2/$3"
	fi
}

#upload to S3 bucket
if [ "x${S3}" = "xyes" ]; then
	# upload to S3 bucket
	cd $BUILDDIR/tmp/deploy/images/imx8mpnavq/
	zip -1 -n bz2 /tmp/${RELEASE_VER}-navqp.zip ${files[*]}
	cd -
	# if version starts with 0. or HEAD, use the "nightly/" folder on S3,
	# otherwise, use "release/"
	echo $RELEASE_VER | grep -o "^0.\|^head"
	if [ $? -eq 0 ]; then
	    path="nightly"
	else
	    path="release"
	fi
	# upload base release bundle zip
	upload_to_s3 /tmp/${RELEASE_VER}-navqp.zip "${path}" ${RELEASE_VER}-navqp.zip
	# upload SD card image for ROS2
	upload_to_s3 $BUILDDIR/tmp/deploy/images/imx8mpnavq/imx-image-desktop-ros-imx8mpnavq.wic.bz2 "${path}" ${RELEASE_VER}-ros2.wic.bz2
	# remove temps
	rm /tmp/${RELEASE_VER}-navqp.zip
fi

finish=`date +%s`; echo "### Build Time = `expr \( $finish - $start \) / 60` minutes"
