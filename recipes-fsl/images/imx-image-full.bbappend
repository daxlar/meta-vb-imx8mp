require imx-image.inc
IMAGE_INSTALL:remove += " \
		     chromium-ozone-wayland \
		     "

IMAGE_INSTALL:append += " \
                         opencv \
                         opencv-apps \
                         opencv-samples \
                         python3-opencv \
                         tensorflow-lite-vx-delegate \
                         packagegroup-imx-ml-desktop \
                         umtp-responder \
                         navq-files \
                         navq-files-wpa \
                        "

IMAGE_INSTALL:append = " \
    ros-core \
    demo-nodes-cpp \
"

APTGET_EXTRA_PACKAGES += " \
		       v4l-utils \
		       iw	 \
		       "
