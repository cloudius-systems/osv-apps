module: hello

include common.gmk

Hello.class: Hello.java $(app-dir)/upstream/graalvm-ce-java11-$(GRAAL_VERSION)
	upstream/graalvm-ce-java11-$(GRAAL_VERSION)/bin/javac -d . Hello.java

hello: Hello.class $(app-dir)/upstream/graalvm-ce-java11-$(GRAAL_VERSION)/bin/native-image
	upstream/graalvm-ce-java11-$(GRAAL_VERSION)/bin/native-image --no-server Hello

clean:
	rm -rf *.class hello upstream
