SCALA:=2.12
VERSION:=2.1.1
NAME:=kafka
DIR:=kafka_$(SCALA)-$(VERSION)
TARBALL:=$(DIR).tgz
URL:=http://archive.apache.org/dist/$(NAME)/$(VERSION)/$(TARBALL)


module: ROOTFS usr.manifest

$(TARBALL):
	wget $(URL)

ROOTFS/$(NAME): $(TARBALL)
	tar xvf $(TARBALL)
	mkdir -p ROOTFS
	mv $(DIR) ROOTFS/$(NAME)
	touch ROOTFS/$(NAME)
	find ./assets/config -type f -exec cp {} ROOTFS/$(NAME)/config/. \;

usr.manifest:
	echo "/$(NAME)/**: \$${MODULE_DIR}/ROOTFS/$(NAME)/**" > usr.manifest

clean:
	rm -rf ROOTFS $(DIR)
	rm -f usr.manifest $(TARBALL)

ROOTFS: ROOTFS/$(NAME)
