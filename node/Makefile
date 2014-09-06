
LIB_NODE = node-$(NODE_VERSION)/out/Release/lib.target/libnode.so

libnode.so: $(LIB_NODE)
	cp $^ $@

$(LIB_NODE):
	cd node-$(NODE_VERSION); ./configure
	$(MAKE) -C node-$(NODE_VERSION)
