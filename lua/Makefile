
LIB_LUA = lua-$(LUA_VERSION)/src/lua.so

liblua.so: $(LIB_LUA)
	cp $^ $@

$(LIB_LUA):
	$(MAKE) -C lua-$(LUA_VERSION) osv

VERSION=5.2.3
module:
	if test ! -d lua-$(VERSION); then ./GET $(VERSION); $(MAKE) LUA_VERSION=$(VERSION); fi
	echo '/liblua.so: $${MODULE_DIR}/liblua.so' > usr.manifest
	: > bootfs.manifest
clean:
	rm -rf lua-$(VERSION) usr.manifest bootfs.manifest liblua.so
